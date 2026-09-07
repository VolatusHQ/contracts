// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {VolatusHook} from "../src/VolatusHook.sol";
import {VolatusVault} from "../src/VolatusVault.sol";
import {VolatusOracle} from "../src/VolatusOracle.sol";
import {VarianceToken} from "../src/VarianceToken.sol";
import {IVolatusHook} from "../src/interfaces/IVolatusHook.sol";
import {MintableERC20} from "../src/mocks/MintableERC20.sol";

/// @notice One-shot testnet bring-up: tokens, hook, vault, oracle, both pools, first epoch.
///
/// @dev Deploys against the real PoolManager. Uses mock tokens deliberately — the demo needs a
///      pool it can make move on cue, which a real pool will not do to order.
///
///          POOL_MANAGER=0x00B036B58a818B1BC34d502D3fE730Db729e62AC \
///          forge script script/DeployTestnet.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast
contract DeployTestnet is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @dev Epoch: ~1 hour of one-second Unichain blocks, band 0 to 0.02 variance.
    uint48 internal constant EPOCH_BLOCKS = 3600;
    uint32 internal constant HORIZON_SECONDS = 3600;
    uint256 internal constant STRIKE = 0;
    uint256 internal constant CAP = 0.02e18;

    /// @dev Starting guess for VAR-LONG, a point to discover from rather than a fair value.
    uint256 internal constant INITIAL_VAR_PRICE = 0.3e18;

    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address me = msg.sender;

        vm.startBroadcast();

        // --- tokens -------------------------------------------------------
        MintableERC20 weth = new MintableERC20("Volatus Mock WETH", "mWETH", 18);
        MintableERC20 usdc = new MintableERC20("Volatus Mock USDC", "mUSDC", 6);

        // Sized against what the seeded position actually consumes, which is ~1.3e19 *units*
        // of each token. mUSDC has 6 decimals, so that is 1.3e13 mUSDC — mint far past it rather
        // than tune it, since these are mocks and the faucet is open anyway.
        weth.mint(me, 1e24);
        usdc.mint(me, 1e24);

        // --- protocol -----------------------------------------------------
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VolatusHook).creationCode, abi.encode(poolManager, me));

        VolatusHook hook = VolatusHook(
            _deployViaCreate2(
                salt, abi.encodePacked(type(VolatusHook).creationCode, abi.encode(poolManager, me)), hookAddress
            )
        );
        require(hook.vaultSetter() == me, "vaultSetter must survive factory deployment");

        VarianceToken tokenImpl = new VarianceToken();
        VolatusVault vault = new VolatusVault(IERC20(address(usdc)), IVolatusHook(address(hook)), address(tokenImpl));
        hook.setVault(address(vault));

        VolatusOracle oracle = new VolatusOracle(poolManager, vault, IVolatusHook(address(hook)), me);

        // --- routers (testnet convenience, not protocol) --------------------
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(poolManager);
        PoolSwapTest swapRouter = new PoolSwapTest(poolManager);

        weth.approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(lpRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);

        // --- the measured pool ---------------------------------------------
        PoolKey memory measured = _key(address(weth), address(usdc), IHooks(address(hook)));
        poolManager.initialize(measured, SQRT_PRICE_1_1);

        lpRouter.modifyLiquidity(
            measured, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 50e18, salt: 0}), ""
        );

        // --- the first epoch -------------------------------------------------
        PoolId measuredId = measured.toId();
        uint256 epochId = vault.openEpoch(measuredId, uint48(block.number) + EPOCH_BLOCKS, HORIZON_SECONDS, STRIKE, CAP);

        address longToken = address(vault.epoch(epochId).longToken);
        address shortToken = address(vault.epoch(epochId).shortToken);

        // --- the vol pool, where implied volatility is discovered -------------
        PoolKey memory volPool = _key(longToken, address(usdc), IHooks(address(0)));
        poolManager.initialize(volPool, _sqrtPriceFor(longToken, address(usdc), INITIAL_VAR_PRICE));
        oracle.registerVolPool(epochId, volPool);

        vm.stopBroadcast();

        console2.log("== Volatus on Unichain Sepolia ==");
        console2.log("deployer          ", me);
        console2.log("VolatusHook         ", address(hook));
        console2.log("VolatusVault        ", address(vault));
        console2.log("VolatusOracle       ", address(oracle));
        console2.log("VarianceToken impl", address(tokenImpl));
        console2.log("mWETH             ", address(weth));
        console2.log("mUSDC             ", address(usdc));
        console2.log("lpRouter          ", address(lpRouter));
        console2.log("swapRouter        ", address(swapRouter));
        console2.log("measured poolId   ", vm.toString(PoolId.unwrap(measuredId)));
        console2.log("epochId           ", epochId);
        console2.log("VAR-LONG          ", longToken);
        console2.log("VAR-SHORT         ", shortToken);
        console2.log("vol poolId        ", vm.toString(PoolId.unwrap(volPool.toId())));
        console2.log("epoch endBlock    ", uint256(block.number) + EPOCH_BLOCKS);
    }

    /// @dev Deploy through the deterministic CREATE2 factory explicitly, rather than relying on
    ///      `new C{salt: s}` being routed there. Foundry's routing differs between simulation and
    ///      broadcast, and a hook whose address is off by one deployer is simply not a hook —
    ///      PoolManager rejects it. Calling the factory directly means the address the miner
    ///      computed is the address that gets code, in both modes.
    ///
    ///      This is only safe because `vaultSetter` is a constructor argument: the factory is
    ///      `msg.sender` inside the constructor, so anything read from `msg.sender` here would
    ///      be the factory.
    function _deployViaCreate2(bytes32 salt, bytes memory initcode, address expected)
        internal
        returns (address deployed)
    {
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode));
        require(ok, "CREATE2 deploy failed");
        require(expected.code.length > 0, "no code at mined address");
        return expected;
    }

    function _key(address a, address b, IHooks hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    /// @dev slot0 stores currency1 per currency0, so invert when VAR-LONG is the second currency.
    function _sqrtPriceFor(address longToken, address collateral, uint256 priceWad) internal pure returns (uint160) {
        uint256 ratioWad = longToken < collateral ? priceWad : Math.mulDiv(1e18, 1e18, priceWad);
        return uint160(Math.sqrt(Math.mulDiv(ratioWad, 1 << 192, 1e18)));
    }
}
