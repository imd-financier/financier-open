// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {RobinhoodFactoryForkTest} from "./RobinhoodFactory.t.sol";
import {IProjectFactory} from "./IProjectFactory.sol";
import {RestrictedMarketReserveReceiver as Receiver} from "../../src/RestrictedMarketReserveReceiver.sol";
import {FinancierMiningWithMarket as Mining} from "../../src/FinancierMiningWithMarket.sol";
import {PermanentV4Market as Market} from "../../src/market/PermanentV4Market.sol";
import {IV4Market} from "../../src/market/IV4Market.sol";
import {V4AttackActor} from "../../test/helpers/Task23Base.sol";
import {AttestedAgentRounds} from "../../src/AttestedAgentRounds.sol";
import {FINCR} from "../../src/FINCR.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Shared existing Task23/24 actual-runtime launch fixture. All authority/funding is fork-only.
abstract contract MarketForkFixture is RobinhoodFactoryForkTest {
    address constant OPS = address(0x230023);
    address constant BOOTSTRAP = address(701);
    Receiver receiver;
    Mining miner;
    FINCR token;
    Market market;
    uint64 number;
    uint128 initialPrincipal;
    bytes32 initialPositionSlot;
    uint160 beforeFirstBid;

    address internal distributor;

    function openingQuote() internal pure virtual returns (uint256) {
        return 0.1 ether;
    }

    function auctionFloor() internal pure virtual returns (uint256) {
        return 0.1 ether;
    }

    function operationsEOA() internal pure virtual returns (address) {
        return OPS;
    }
    function beforeBootstrap() internal virtual {}
    function afterArm() internal virtual {}

    function setUp() public override {
        super.setUp();
        FINCR probe = new FINCR(1e27);
        bytes memory tc = abi.encodePacked(type(FINCR).creationCode, abi.encode(uint256(1e27)));
        Receiver.Pins memory pins = Receiver.Pins(
            address(FACTORY),
            FACTORY.registry(),
            FACTORY.deployer(),
            address(FACTORY).codehash,
            FACTORY.registry().codehash,
            keccak256(tc),
            address(probe).codehash,
            keccak256(type(Mining).creationCode),
            type(Mining).creationCode.length
        );
        Receiver.Settings memory settings = Receiver.Settings(
            params().pairedCurrency,
            1e27,
            openingQuote(),
            auctionFloor(),
            operationsEOA(),
            address(702),
            keccak256("LOCAL ONLY"),
            1 days,
            1 days,
            1 hours,
            0.1 ether
        );
        receiver = new Receiver(pins, settings, BOOTSTRAP);
        IProjectFactory.CustomParams memory p = customFincrParams(9_230_000);
        number = p.launchNumber;
        p.remainderTo = address(receiver);
        p.requester = address(this);
        p.contractCreationCodes = new bytes[](1);
        p.contractNames = new bytes32[](1);
        p.expectedContracts = new address[](1);
        p.contractNames[0] = "FinancierMiningWithMarket";
        p.contractCreationCodes[0] = bytes.concat(
            type(Mining).creationCode, receiver.minerArguments(FACTORY.predictToken(number, p.tokenCreationCode))
        );
        p.expectedContracts[0] = FACTORY.predictContract(number, 0, p.contractCreationCodes[0]);
        vm.prank(FACTORY.deployer());
        (address t, address[] memory apps, address distributor_) = FACTORY.launchCustom(p);
        distributor = distributor_;
        assertEq(FINCR(t).balanceOf(distributor), 1e26);
        token = FINCR(t);
        miner = Mining(apps[0]);
        market = miner.market();
        assertEq(token.totalSupply(), 1e27);
        uint256 remainder = token.balanceOf(address(receiver));
        uint256 poolInventory = token.balanceOf(market.MANAGER());
        assertGe(remainder, 4e26);
        assertLe(poolInventory, 5e26);
        assertEq(poolInventory + remainder, 9e26); // Other 10% is the factory swarm allocation.
        emit log_named_uint("Initial actual pool FINCR inventory", poolInventory);
        emit log_named_uint("Initial actual receiver FINCR including pool rounding", remainder);
        emit log_named_uint("Exact mining reserve transferred", 4e26);
        beforeBootstrap();
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(
            number, p.tokenCreationCode, p.contractCreationCodes[0], keccak256("LOCAL review, not source admission")
        );
        (, int24 lower, int24 upper,) = FACTORY.positionOf(number);
        initialPositionSlot = positionSlot(address(FACTORY), lower, upper, 0);
        initialPrincipal = uint128(uint256(IV4Market(market.MANAGER()).extsload(initialPositionSlot)));
        beforeFirstBid = market.spot();
        emit log_named_uint("Recorded launcher fixture liquidity (scaled 50/88)", p.liquidity);
        emit log_named_uint("Factory initial sqrtPriceX96", beforeFirstBid);
        afterArm();
        uint256 price = miner.currentPrice();
        deal(p.pairedCurrency, address(101), price);
        vm.startPrank(address(101));
        IERC20(p.pairedCurrency).approve(address(miner), price);
        uint256 g = gasleft();
        miner.bid{gas: 2_000_000}(0, price, block.timestamp);
        emit log_named_uint("Fork automatic genesis bid execution gas", g - gasleft());
        vm.stopPrank();
    }

    function nextBid(uint256 gasLimit) internal {
        address bob = address(102);
        deal(miner.WORK_ASSET(), bob, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        uint256 e = miner.epoch();
        uint256 p = miner.currentPrice();
        vm.startPrank(bob);
        IERC20(miner.WORK_ASSET()).approve(address(miner), 1 ether);
        uint256 g = gasleft();
        miner.bid{gas: gasLimit}(e, p, block.timestamp);
        emit log_named_uint("Fork automatic takeover execution gas", g - gasleft());
        vm.stopPrank();
    }

    function positionSlot(address owner, int24 lower, int24 upper, bytes32 salt) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(abi.encodePacked(owner, lower, upper, salt)),
                uint256(keccak256(abi.encode(market.poolId(), uint256(6)))) + 6
            )
        );
    }
}
