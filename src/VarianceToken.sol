// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title VarianceToken
/// @notice One leg of one epoch's variance pair: VAR-LONG or VAR-SHORT.
///
/// @dev A deliberately minimal ERC-20. It is an ERC-20 and not an ERC-6909 because a Uniswap v4
///      pool currency is `type Currency is address` — identified by address alone, with nowhere
///      to put a token id — and because `CurrencyLibrary` hard-codes the ERC-20 selectors. See
///      `DECISIONS.md` §1 and `test/integration/PoolCurrencyConstraint.t.sol`, which proves both.
///      VAR-LONG has to be a pool currency; therefore it has to be an ERC-20, one address per
///      leg per epoch.
///
///      There is no constructor state, so the implementation can be deployed once and each
///      epoch's legs created as EIP-1167 clones. With `cloneDeterministic` this also makes a
///      leg's address computable before its epoch opens, so the vol pool's `PoolKey` is known
///      in advance rather than discovered after deployment.
///
///      Minting and burning are restricted to the vault that initialized the clone. The vault
///      is the only contract that can create or destroy supply, and it does so only against
///      collateral it holds — which is what makes the solvency invariant structural.
contract VarianceToken {
    // -------------------------------------------------------------------------
    // ERC-20 state
    // -------------------------------------------------------------------------

    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice The vault permitted to mint and burn. Set once, at initialization.
    address public vault;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error AlreadyInitialized();
    error NotVault();
    error InvalidVault();
    /// @dev Transferring to the zero address burns silently in naive implementations; here it
    ///      is rejected, because a leg burned outside the vault would leave collateral stranded
    ///      with no claim against it.
    error TransferToZeroAddress();

    /// @notice Initializes a clone. Callable exactly once, by whoever creates the clone.
    /// @dev The implementation contract itself is left uninitialized on purpose; there is
    ///      nothing to seize, since it holds no collateral and its `vault` stays unset, which
    ///      makes `mint` and `burn` permanently unreachable on it.
    function initialize(string memory name_, string memory symbol_, uint8 decimals_, address vault_) external {
        if (vault != address(0)) revert AlreadyInitialized();
        if (vault_ == address(0)) revert InvalidVault();

        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    // -------------------------------------------------------------------------
    // Supply, controlled entirely by the vault
    // -------------------------------------------------------------------------

    function mint(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert TransferToZeroAddress();

        totalSupply += amount;
        unchecked {
            // Cannot overflow: a balance is bounded by totalSupply, which was just checked.
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        balanceOf[from] -= amount; // reverts on insufficient balance
        unchecked {
            // Cannot underflow: the balance was at least `amount`, and it is part of the total.
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    // -------------------------------------------------------------------------
    // ERC-20
    // -------------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];

        // An infinite allowance is not decremented, the conventional gas optimization.
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount; // reverts if not allowed
        }

        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        if (to == address(0)) revert TransferToZeroAddress();

        balanceOf[from] -= amount; // reverts on insufficient balance
        unchecked {
            // Cannot overflow: the sum of all balances is totalSupply.
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
        return true;
    }
}
