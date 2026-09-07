// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {VarianceToken} from "../../src/VarianceToken.sol";

contract VarianceTokenTest is Test {
    VarianceToken internal implementation;
    VarianceToken internal token;

    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        implementation = new VarianceToken();
        token = VarianceToken(Clones.clone(address(implementation)));
        token.initialize("Volatus VAR-LONG epoch 1", "vLONG-1", 6, vault);
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(vault);
        token.mint(to, amount);
    }

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    function test_initializeSetsMetadata() public view {
        assertEq(token.name(), "Volatus VAR-LONG epoch 1");
        assertEq(token.symbol(), "vLONG-1");
        assertEq(token.decimals(), 6, "legs mirror the collateral's decimals");
        assertEq(token.vault(), vault);
        assertEq(token.totalSupply(), 0);
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert(VarianceToken.AlreadyInitialized.selector);
        token.initialize("hijack", "HJK", 18, address(0xBAD));

        assertEq(token.vault(), vault, "the original vault stands");
    }

    function test_cannotInitializeWithZeroVault() public {
        VarianceToken fresh = VarianceToken(Clones.clone(address(implementation)));
        vm.expectRevert(VarianceToken.InvalidVault.selector);
        fresh.initialize("x", "X", 6, address(0));
    }

    /// @notice The implementation is deliberately left uninitialized. It must be inert: no
    ///         vault means minting on it is permanently unreachable.
    function test_implementationIsInert() public {
        assertEq(implementation.vault(), address(0));

        vm.expectRevert(VarianceToken.NotVault.selector);
        implementation.mint(alice, 1e6);
    }

    /// @notice Clones are independent — one epoch's legs cannot touch another's.
    function test_clonesAreIndependent() public {
        VarianceToken other = VarianceToken(Clones.clone(address(implementation)));
        other.initialize("Volatus VAR-SHORT epoch 1", "vSHORT-1", 6, vault);

        _mint(alice, 1000e6);

        assertEq(token.balanceOf(alice), 1000e6);
        assertEq(other.balanceOf(alice), 0, "separate ledgers");
        assertEq(other.totalSupply(), 0);
        assertTrue(address(token) != address(other));
    }

    /// @notice `cloneDeterministic` is what makes a leg's address knowable before its epoch
    ///         opens, so the vol pool's PoolKey can be built in advance.
    function test_deterministicCloneAddressIsPredictable() public {
        bytes32 salt = keccak256("epoch-7-long");

        address predicted = Clones.predictDeterministicAddress(address(implementation), salt, address(this));
        address actual = Clones.cloneDeterministic(address(implementation), salt);

        assertEq(actual, predicted, "the address is known before deployment");
    }

    // -------------------------------------------------------------------------
    // Supply control
    // -------------------------------------------------------------------------

    function test_onlyVaultCanMint() public {
        vm.expectRevert(VarianceToken.NotVault.selector);
        vm.prank(alice);
        token.mint(alice, 1e6);
    }

    function test_onlyVaultCanBurn() public {
        _mint(alice, 1e6);

        vm.expectRevert(VarianceToken.NotVault.selector);
        vm.prank(alice);
        token.burn(alice, 1e6);
    }

    function test_mintAndBurnTrackTotalSupply() public {
        _mint(alice, 1000e6);
        assertEq(token.totalSupply(), 1000e6);
        assertEq(token.balanceOf(alice), 1000e6);

        vm.prank(vault);
        token.burn(alice, 400e6);

        assertEq(token.totalSupply(), 600e6);
        assertEq(token.balanceOf(alice), 600e6);
    }

    function test_burnCannotExceedBalance() public {
        _mint(alice, 100e6);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(vault);
        token.burn(alice, 100e6 + 1);
    }

    function test_mintToZeroAddressReverts() public {
        vm.expectRevert(VarianceToken.TransferToZeroAddress.selector);
        vm.prank(vault);
        token.mint(address(0), 1e6);
    }

    // -------------------------------------------------------------------------
    // ERC-20 behaviour
    // -------------------------------------------------------------------------

    function test_transfer() public {
        _mint(alice, 100e6);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 40e6));

        assertEq(token.balanceOf(alice), 60e6);
        assertEq(token.balanceOf(bob), 40e6);
        assertEq(token.totalSupply(), 100e6, "transfers never change supply");
    }

    function test_transferCannotExceedBalance() public {
        _mint(alice, 100e6);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        token.transfer(bob, 100e6 + 1);
    }

    /// @notice A leg sent to address(0) outside the vault would strand collateral with no claim
    ///         against it, so it is rejected rather than treated as a burn.
    function test_transferToZeroAddressReverts() public {
        _mint(alice, 100e6);

        vm.expectRevert(VarianceToken.TransferToZeroAddress.selector);
        vm.prank(alice);
        token.transfer(address(0), 1e6);
    }

    function test_transferFromSpendsAllowance() public {
        _mint(alice, 100e6);

        vm.prank(alice);
        token.approve(bob, 60e6);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 25e6));

        assertEq(token.allowance(alice, bob), 35e6, "allowance decremented");
        assertEq(token.balanceOf(bob), 25e6);
    }

    function test_transferFromCannotExceedAllowance() public {
        _mint(alice, 100e6);

        vm.prank(alice);
        token.approve(bob, 10e6);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10e6 + 1);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        _mint(alice, 100e6);

        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        token.transferFrom(alice, bob, 50e6);

        assertEq(token.allowance(alice, bob), type(uint256).max, "left untouched");
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

    /// @notice Supply is conserved by every operation that is not a mint or a burn. The vault's
    ///         solvency argument rests on this.
    function testFuzz_transfersConserveSupply(uint128 minted, uint128 sent, address to) public {
        vm.assume(to != address(0) && to != alice);
        sent = uint128(bound(sent, 0, minted));

        _mint(alice, minted);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(to, sent);

        assertEq(token.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(token.balanceOf(alice) + token.balanceOf(to), minted, "and conserved across holders");
    }

    function testFuzz_mintThenBurnIsIdentity(uint128 amount) public {
        _mint(alice, amount);

        vm.prank(vault);
        token.burn(alice, amount);

        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
    }
}
