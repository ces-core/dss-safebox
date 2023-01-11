// SPDX-FileCopyrightText: © 2022 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
pragma solidity ^0.8.16;

import {VatAbstract} from "dss-interfaces/dss/VatAbstract.sol";
import {GemAbstract} from "dss-interfaces/ERC/GemAbstract.sol";

/**
 * @author amusingaxl
 * @title A safebox for ERC-20 tokens.
 * @notice
 * - The `owner`(MakerDAO Governance) can request funds to be sent to `recipient`.
 * - The `custodian`(Coinbase) can deny a request for funds up to `WITHDRAWAL_TIMELOCK` after it was made.
 * - If MakerDAO governance ever executes an Emergency Shutdown, anyone can send tokens to `recipient`.
 *     - This prevents tokens being stuck in this contract when the governance smart contract is no longer operational.
 * - The `custodian` cooperation is required whenever the `owner` wants to update the `recipient`.
 */
contract Safebox {
    /// @notice Time window through which the custodian can deny a withdrawal request.
    uint256 public constant WITHDRAWAL_TIMELOCK = 1 days;

    /// @notice MCD Vat module.
    VatAbstract public immutable vat;
    /// @notice The ERC-20 token to be held in this contract.
    GemAbstract public immutable token;

    /// @notice Addresses with owner access on this contract. `wards[usr]`
    mapping(address => uint256) public wards;

    /// @notice The recipient for the tokens held in this contract.
    address public recipient;
    /// @notice Reference to the new recipient when it is to be changed.
    address public pendingRecipient;

    /// @notice The last time a withdrawal request was made.
    uint256 public requestedWithdrawalTime;
    /// @notice The last withdrawal request amount.
    uint256 public requestedWithdrawalAmount;

    /**
     * @notice `usr` was granted owner access.
     * @param usr The user address.
     */
    event Rely(address indexed usr);
    /**
     * @notice `usr` owner access was revoked.
     * @param usr The user address.
     */
    event Deny(address indexed usr);
    /**
     * @notice A contract parameter was updated.
     * @param what The changed parameter name. The supported values are: "recipient".
     * @param data The new value of the parameter.
     */
    event File(bytes32 indexed what, address data);
    /**
     * @notice A withdrawal was requested.
     * @param sender The request sender.
     * @param amount The requested amount.
     */
    event RequestWithdrawal(address indexed sender, uint256 amount);
    /**
     * @notice A withdrawal was executed.
     * @param sender The request sender.
     * @param recipient The recipient for the withdrawal.
     * @param amount The amount withdrawn.
     */
    event ExecuteWithdrawal(address indexed sender, address indexed recipient, uint256 amount);
    /**
     * @notice A withdrawal was canceled by the owner.
     * @param sender The request sender.
     * @param amount The amount of the canceled withdrawal.
     */
    event CancelWithdrawal(address indexed sender, uint256 amount);
    /**
     * @notice A withdrawal request was denied.
     * @param sender The request sender.
     * @param amount The requested sender.
     */
    event DenyWithdrawal(address indexed sender, uint256 amount);
    /**
     * @notice `usr` was granted custodian access.
     * @param usr The user address.
     */
    event AddCustodian(address indexed usr);
    /**
     * @notice `usr` custodian access was revoked.
     * @param usr The user address.
     */
    event RemoveCustodian(address indexed usr);
    /**
     * @notice The recipient has been set.
     * @param recipient The new recipient address.
     */
    event SetRecipient(address indexed recipient);

    /**
     * @param _vat The MCD vat module.
     * @param _token The ERC-20 token to be held in this contract.
     * @param _owner The safebox owner.
     * @param _custodian The safebox custodian.
     * @param _recipient The recipient for tokens in the safebox.
     */
    constructor(address _vat, address _token, address _owner, address _custodian, address _recipient) {
        require(_recipient != address(0), "Safebox/invalid-recipient");

        vat = VatAbstract(_vat);
        token = GemAbstract(_token);
        requestedWithdrawalTime = 0;
        requestedWithdrawalAmount = 0;

        wards[_owner] = 1;
        emit Rely(_owner);

        custodians[_custodian] = 1;
        emit AddCustodian(_custodian);

        recipient = _recipient;
        emit SetRecipient(_recipient);
    }

    /*//////////////////////////////////
                 Operations
    //////////////////////////////////*/

    /**
     * @notice Request a withdrawal of tokens from this contract.
     * @dev Anyone can call this function after MakerDAO governance executes an Emergency Shutdown.
     * @param amount The amount of tokens.
     */
    function requestWithdrawal(uint256 amount) external {
        require(wards[msg.sender] == 1 || vat.live() == 0, "Safebox/not-ward");
        require(requestedWithdrawalTime == 0, "Safebox/pending-withdrawal");
        require(amount > 0, "Safebox/invalid-amount");

        requestedWithdrawalAmount = amount;
        requestedWithdrawalTime = block.timestamp;

        emit RequestWithdrawal(msg.sender, amount);
    }

    /**
     * @notice Cancels a withdrawal request.
     */
    function cancelWithdrawal() external auth {
        require(requestedWithdrawalTime > 0 && requestedWithdrawalAmount > 0, "Safebox/no-pending-withdrawal");

        uint256 amount = requestedWithdrawalAmount;
        requestedWithdrawalAmount = 0;
        requestedWithdrawalTime = 0;

        emit CancelWithdrawal(msg.sender, amount);
    }

    /**
     * @notice Executes a withdrawal request of tokens from this contract.
     * @dev Custodian can call this function any time. Anyone can call this after the WITHDRAWL_DELAY period.
     */
    function executeWithdrawal() external {
        require(requestedWithdrawalTime > 0 && requestedWithdrawalAmount > 0, "Safebox/no-pending-withdrawal");
        require(
            (custodians[msg.sender] == 1) || (requestedWithdrawalTime + WITHDRAWAL_TIMELOCK < block.timestamp),
            "Safebox/ative-timelock"
        );

        uint256 amount = requestedWithdrawalAmount;
        requestedWithdrawalAmount = 0;
        requestedWithdrawalTime = 0;

        token.transfer(recipient, amount);

        emit ExecuteWithdrawal(msg.sender, recipient, amount);
    }

    /**
     * @notice Denies a withdrawal request.
     */
    function denyWithdrawal() external onlyCustodian {
        uint256 amount = requestedWithdrawalAmount;
        requestedWithdrawalAmount = 0;
        requestedWithdrawalTime = 0;

        emit DenyWithdrawal(msg.sender, amount);
    }

    /*//////////////////////////////////
            MakerDAO Interfaces
    //////////////////////////////////*/

    modifier auth() {
        require(wards[msg.sender] == 1, "Safebox/not-ward");
        _;
    }

    /**
     * @notice Grants `usr` owner access to this contract.
     * @param usr The user address.
     */
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /**
     * @notice Revokes `usr` owner access from this contract.
     * @param usr The user address.
     */
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    /**
     * @notice Updates a contract parameter.
     * @dev When setting the `recipient`, `data` cannot be `address(0)` because
     * we need to make sure `pendingRecipient` will only work if it is initialized.
     * @param what The changed parameter name. `"recipient"`
     * @param data The new value of the parameter.
     */
    function file(bytes32 what, address data) external auth {
        require(vat.live() == 1, "Safebox/vat-not-live");

        if (what == "recipient") {
            require(data != address(0), "Safebox/invalid-recipient");
            pendingRecipient = data;
            emit File(what, data);
        } else {
            revert("Safebox/file-unrecognized-param");
        }
    }

    /*//////////////////////////////////
            Custodian Interfaces
    //////////////////////////////////*/

    /// @notice Addresses with custodian access on this contract. `custodians[usr]`
    mapping(address => uint256) public custodians;

    modifier onlyCustodian() {
        require(custodians[msg.sender] == 1, "Safebox/not-custodian");
        _;
    }

    /**
     * @notice Check if an address has `owner` access on this contract.
     * @param usr The user address.
     * @return Whether `usr` is a ward or not.
     */
    function isOwner(address usr) external view returns (bool) {
        return wards[usr] == 1;
    }

    /**
     * @notice Check if an address has `custodian` access on this contract.
     * @param usr The user address.
     * @return Whether `usr` is a custodian or not.
     */
    function isCustodian(address usr) external view returns (bool) {
        return custodians[usr] == 1;
    }

    /**
     * @notice Adds a new custodian to this contract.
     * @param usr The user address.
     */
    function addCustodian(address usr) external onlyCustodian {
        custodians[usr] = 1;
        emit AddCustodian(usr);
    }

    /**
     * @notice Removes a custodian from this contract.
     * @param usr The user address.
     */
    function removeCustodian(address usr) external onlyCustodian {
        custodians[usr] = 0;
        emit RemoveCustodian(usr);
    }

    /**
     * @notice Approves the change in the recipient.
     * @dev Reverts if `pendingRecipient` has not been set or if `_recipient` does not match it.
     * @param _recipient The new recipient being approved.
     */
    function approveChangeRecipient(address _recipient) external onlyCustodian {
        require(pendingRecipient != address(0) && pendingRecipient == _recipient, "Safebox/recipient-mismatch");

        recipient = _recipient;
        pendingRecipient = address(0);

        emit SetRecipient(_recipient);
    }
}
