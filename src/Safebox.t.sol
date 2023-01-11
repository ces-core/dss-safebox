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

import {Test} from "forge-std/Test.sol";
import {ERC20 as ERC20Abstract} from "solmate/tokens/ERC20.sol";
import {Safebox} from "./Safebox.sol";

contract SafeboxTest is Test {
    Safebox internal safebox;
    ERC20 internal usdx = new ERC20("USDX", "USDX", 18);

    FakeVatLiveness internal vat = new FakeVatLiveness();
    address internal owner = address(this);
    address internal custodian = address(0x1337);
    address internal recipient = address(0x2448);

    function setUp() public {
        safebox = new Safebox(address(vat), address(usdx), owner, custodian, recipient);
    }

    function testConstructorRevertWhenRecipientIsInvalid() public {
        vm.expectRevert("Safebox/invalid-recipient");
        new Safebox(address(vat), address(usdx), owner, custodian, address(0));
    }

    function testGiveRightPermissionsUponCreation() public {
        vm.expectEmit(true, false, false, false);
        emit Rely(owner);
        vm.expectEmit(true, false, false, false);
        emit AddCustodian(custodian);
        safebox = new Safebox(address(vat), address(usdx), owner, custodian, recipient);

        assertEq(safebox.wards(owner), 1, "Owner was not relied");
        assertEq(safebox.custodians(custodian), 1, "Custodian was not hoped");
    }

    function testRelyDeny() public {
        assertEq(safebox.wards(address(1)), 0, "Pre-condition failed: ward already set");

        // --------------------
        vm.expectEmit(true, false, false, false);
        emit Rely(address(1));

        safebox.rely(address(1));

        assertEq(safebox.wards(address(1)), 1, "Post-condition failed: ward not set");

        // --------------------
        vm.expectEmit(true, false, false, false);
        emit Deny(address(1));

        safebox.deny(address(1));

        assertEq(safebox.wards(address(1)), 0, "Pre-condition failed: ward not removed");
    }

    function testAddRemoveCustodian() public {
        vm.startPrank(custodian);

        assertEq(safebox.custodians(address(1)), 0, "Pre-condition failed: ward already set");

        // --------------------
        vm.expectEmit(true, false, false, false);
        emit AddCustodian(address(1));

        safebox.addCustodian(address(1));

        assertEq(safebox.custodians(address(1)), 1, "Post-condition failed: ward not set");

        // --------------------
        vm.expectEmit(true, false, false, false);
        emit RemoveCustodian(address(1));

        safebox.removeCustodian(address(1));

        assertEq(safebox.custodians(address(1)), 0, "Pre-condition failed: ward not removed");
    }

    function testOwnerCanRequestWithdrawal() public {
        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        vm.expectEmit(true, true, false, true);
        emit RequestWithdrawal(address(this), amount);

        safebox.requestWithdrawal(amount);
    }

    function testRevertRequestWithdrawalOfZero() public {
        vm.expectRevert("Safebox/invalid-amount");
        safebox.requestWithdrawal(0);
    }

    function testRevertRequestMultipleWithdrawals() public {
        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        safebox.requestWithdrawal(amount);

        vm.expectRevert("Safebox/pending-withdrawal");
        safebox.requestWithdrawal(amount + 1);
    }

    function testFuzzRevertRequestWithdrawalWhenNotOwner(address sender) public {
        vm.assume(sender != owner);

        uint256 amount = 123;
        usdx.mint(address(safebox), amount);
        assertEq(usdx.balanceOf(address(safebox)), amount);

        vm.expectRevert("Safebox/not-ward");

        vm.startPrank(sender);
        safebox.requestWithdrawal(amount);
    }

    function testFuzzAnyoneCanRequestWithdrawalWhenVatIsNotLive(address sender) public {
        vm.assume(sender != owner && sender != address(safebox));
        vat.cage();

        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        assertEq(usdx.balanceOf(address(safebox)), amount, "Pre-condition failed: bad safebox balance");
        assertEq(usdx.balanceOf(recipient), 0, "Pre-condition failed: recipient balance not zero");

        vm.expectEmit(true, false, false, true);
        emit RequestWithdrawal(sender, amount);

        vm.startPrank(sender);
        safebox.requestWithdrawal(amount);
    }

    function testOwnerCanCancelWithdrawal() public {
        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        assertEq(usdx.balanceOf(address(safebox)), amount, "Pre-condition failed: bad safebox balance");
        assertEq(usdx.balanceOf(recipient), 0, "Pre-condition failed: recipient balance not zero");

        safebox.requestWithdrawal(amount);

        vm.expectEmit(true, false, false, true);
        emit CancelWithdrawal(address(this), amount);

        safebox.cancelWithdrawal();

        assertEq(usdx.balanceOf(address(safebox)), amount, "Post-condition failed: bad safebox balance");
        assertEq(usdx.balanceOf(recipient), 0, "Post-condition failed: recipient balance not zero");
    }

    function testRevertRevertCancelWithdrawalWhenNotRequested() public {
        vm.expectRevert("Safebox/no-pending-withdrawal");
        safebox.cancelWithdrawal();
    }

    function testCustodianCanExecuteWithdrawalImmediately() public {
        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        assertEq(usdx.balanceOf(address(safebox)), amount, "Pre-condition failed: bad safebox balance");
        assertEq(usdx.balanceOf(recipient), 0, "Pre-condition failed: recipient balance not zero");

        safebox.requestWithdrawal(amount);

        vm.expectEmit(true, true, false, true);
        emit ExecuteWithdrawal(custodian, recipient, amount);

        vm.startPrank(custodian);
        safebox.executeWithdrawal();

        assertEq(usdx.balanceOf(address(safebox)), 0, "Post-condition failed: invalid safebox balance");
        assertEq(usdx.balanceOf(recipient), amount, "Post-condition failed: invalid recipient balance");
    }

    function testFuzzAnyoneCanExecuteWithdrawalAfterTimelock(address sender) public {
        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        assertEq(usdx.balanceOf(address(safebox)), amount, "Pre-condition failed: bad safebox balance");
        assertEq(usdx.balanceOf(recipient), 0, "Pre-condition failed: recipient balance not zero");

        safebox.requestWithdrawal(amount);
        skip(safebox.WITHDRAWAL_TIMELOCK() + 1);

        vm.expectEmit(true, true, false, true);
        emit ExecuteWithdrawal(sender, recipient, amount);

        vm.startPrank(sender);
        safebox.executeWithdrawal();

        assertEq(usdx.balanceOf(address(safebox)), 0, "Post-condition failed: invalid safebox balance");
        assertEq(usdx.balanceOf(recipient), amount, "Post-condition failed: invalid recipient balance");
    }

    function testFuzzRevertExecuteWithdrawalBeforeTimelock(address sender) public {
        vm.assume(sender != custodian);

        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        assertEq(usdx.balanceOf(address(safebox)), amount, "Pre-condition failed: bad safebox balance");
        assertEq(usdx.balanceOf(recipient), 0, "Pre-condition failed: recipient balance not zero");

        safebox.requestWithdrawal(amount);
        skip(safebox.WITHDRAWAL_TIMELOCK() - 1);

        vm.expectRevert("Safebox/ative-timelock");
        vm.startPrank(sender);
        safebox.executeWithdrawal();
    }

    function testRevertExecuteWithdrawalWhenNotRequested() public {
        vm.expectRevert("Safebox/no-pending-withdrawal");
        safebox.executeWithdrawal();
    }

    function testRevertExecuteADeniedWithdrawal() public {
        uint256 amount = 123;
        usdx.mint(address(safebox), amount);

        assertEq(usdx.balanceOf(address(safebox)), amount, "Pre-condition failed: bad safebox balance");
        assertEq(usdx.balanceOf(recipient), 0, "Pre-condition failed: recipient balance not zero");

        safebox.requestWithdrawal(amount);

        vm.expectEmit(true, true, false, true);
        emit DenyWithdrawal(custodian, amount);

        vm.prank(custodian);
        safebox.denyWithdrawal();

        skip(safebox.WITHDRAWAL_TIMELOCK() + 1);

        vm.expectRevert("Safebox/no-pending-withdrawal");
        safebox.executeWithdrawal();
    }

    function testRevertDenyWhenNotCustodian(address sender) public {
        vm.assume(sender != custodian);

        vm.expectRevert("Safebox/not-custodian");

        vm.prank(sender);
        safebox.denyWithdrawal();
    }

    function testChangeRecipient() public {
        address newRecipient = address(0xd34d);
        safebox.file("recipient", newRecipient);

        assertEq(safebox.pendingRecipient(), newRecipient, "Post-condition: failed to set pending recipient");

        vm.prank(address(custodian));
        safebox.approveChangeRecipient(newRecipient);

        assertEq(
            safebox.pendingRecipient(),
            address(0),
            "Post-condition: failed to reset pending recipient after approve"
        );
        assertEq(safebox.recipient(), newRecipient, "Post-condition: failed to set recipient after approve");
    }

    function testRevertChangeRecipientWithInvalidAddress() public {
        vm.expectRevert("Safebox/invalid-recipient");

        safebox.file("recipient", address(0));
    }

    function testRevertChangeRecipientWhenNotCustodian() public {
        address newRecipient = address(0xd34d);
        safebox.file("recipient", newRecipient);

        assertEq(safebox.pendingRecipient(), newRecipient, "Post-condition: failed to set pending recipient");

        vm.expectRevert("Safebox/not-custodian");

        vm.prank(address(0xd34d));
        safebox.approveChangeRecipient(newRecipient);
    }

    function testRevertChangeRecipientWithMismatchingAddresses() public {
        address newRecipient = address(0xd34d);
        safebox.file("recipient", newRecipient);

        assertEq(safebox.pendingRecipient(), newRecipient, "Post-condition: failed to set pending recipient");

        vm.expectRevert("Safebox/recipient-mismatch");

        vm.prank(address(custodian));
        safebox.approveChangeRecipient(address(0x1234));
    }

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event AddCustodian(address indexed usr);
    event RemoveCustodian(address indexed usr);
    event File(bytes32 indexed what, address data);
    event RecipientChange(address indexed recipient);
    event RequestWithdrawal(address indexed sender, uint256 amount);
    event ExecuteWithdrawal(address indexed sender, address indexed recipient, uint256 amount);
    event CancelWithdrawal(address indexed sender, uint256 amount);
    event DenyWithdrawal(address indexed sender, uint256 amount);
}

contract ERC20 is ERC20Abstract {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20Abstract(name, symbol, decimals) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract FakeVatLiveness {
    uint256 public live = 1;

    function cage() external {
        live = 0;
    }
}
