// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPool } from "../interfaces/IPool.sol";
import { DataTypes } from "../interfaces/DataTypes.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IPoolAddressesProvider } from "../interfaces/IPoolAddressesProvider.sol";
import { IAToken } from "../interfaces/IAToken.sol";

import { StrategyManagerFactory } from "../StrategyManagerFactory.sol";
import { StrategyManager } from "../StrategyManager.sol";

contract UiDataProvider {
    struct UserStrategy {
        address manager;
        address pool;
        address yieldAsset;
        address debtAsset;
        string yieldSymbol;
        string debtSymbol;
    }

    struct UserStrategies {
        address user;
        UserStrategy[] strategyManagers;
    }

    struct StrategyDetailed {
        address manager;
        address pool;
        address yieldAsset;
        address debtAsset;
        uint256 healthFactor;
        int256 positionValueUsd;
        uint256 leverage;
        uint256 liquidationThreshold;
        uint256 yieldLiquidityRate;
        uint256 debtVariableBorrowRate;
        string yieldSymbol;
        string debtSymbol;
        Balances balances;
    }

    struct Balances {
        uint256 debtBalance;
        uint256 yieldBalance;
        uint256 debtValueUsd;
        uint256 yieldValueUsd;
    }

    function getUserStrategies(address _factory, address _user) public view returns (UserStrategies memory) {
        StrategyManagerFactory factory = StrategyManagerFactory(_factory);
        
        address[] memory managers = factory.getUserStrategyManagers(_user);
        UserStrategy[] memory userStrategyArray = new UserStrategy[](managers.length);

        for (uint256 i = 0; i < managers.length; i++){
            StrategyManager manager = StrategyManager(managers[i]);

            userStrategyArray[i] = UserStrategy({
                manager: managers[i],
                pool: manager.pool(),
                yieldAsset: manager.yieldAsset(),
                debtAsset: manager.debtAsset(),
                yieldSymbol: IERC20Metadata(manager.yieldAsset()).symbol(),
                debtSymbol: IERC20Metadata(manager.debtAsset()).symbol()
            });
        }

        UserStrategies memory userStrategies = UserStrategies({
            user: _user,
            strategyManagers: userStrategyArray
        });

        return userStrategies;
    }

    function getUserStrategiesDetailed(address _factory, address _user) public view returns (StrategyDetailed[] memory){
        StrategyManagerFactory factory = StrategyManagerFactory(_factory);
        address[] memory managers = factory.getUserStrategyManagers(_user);

        StrategyDetailed[] memory userStrategyDetailedArray = new StrategyDetailed[](managers.length * 2);
        uint256 j = 0;
        for (uint256 i = 0; i < managers.length; i++){
            //add normal position
            userStrategyDetailedArray[j] = getStrategy(managers[i], false);
            j++;
            //check if user has any "inverted" positions
            userStrategyDetailedArray[j] = getStrategy(managers[i], true);
            j++;
        }

        return userStrategyDetailedArray;
    }

    struct LocalVars {
        address yieldAssetAddr;
        address debtAssetAddr;
        DataTypes.ReserveData yieldReserve;
        DataTypes.ReserveData debtReserve;
        IAToken aYieldToken;
        IAToken variableDebtToken;
        uint256 debtPrice;
        uint256 yieldPrice;
        uint256 denominator;
    }

    function getStrategy(address _manager, bool _invert) public view returns (StrategyDetailed memory) {
        StrategyManager manager = StrategyManager(_manager);

        //invert yield and debt asset
        if (_invert){
            address yieldAssetAddrInv = manager.debtAsset();
            address debtAssetAddrInv = manager.yieldAsset();
            return getStrategy(_manager, yieldAssetAddrInv, debtAssetAddrInv);
        }

        address yieldAssetAddr = manager.yieldAsset();
        address debtAssetAddr = manager.debtAsset();
        return getStrategy(_manager, yieldAssetAddr, debtAssetAddr);
    }

    function getStrategy(address _manager, address yieldAsset, address debtAsset) public view returns (StrategyDetailed memory) {
        StrategyManager manager = StrategyManager(_manager);
        IPool pool = IPool(manager.pool());

        address oracleAddress = IPoolAddressesProvider(pool.ADDRESSES_PROVIDER()).getPriceOracle();
        IOracle oracle = IOracle(oracleAddress);

        uint256 debtValueUsd;
        uint256 yieldValueUsd;
        uint256 leverage;

        LocalVars memory vars;
        {
            vars.yieldReserve = pool.getReserveData(yieldAsset);
            vars.debtReserve = pool.getReserveData(debtAsset);

            vars.aYieldToken = IAToken(vars.yieldReserve.aTokenAddress);
            vars.variableDebtToken = IAToken(vars.debtReserve.variableDebtTokenAddress);

            vars.debtPrice = oracle.getAssetPrice(debtAsset);
            vars.yieldPrice = oracle.getAssetPrice(yieldAsset);

            yieldValueUsd = vars.aYieldToken.balanceOf(_manager) * vars.yieldPrice; 
            debtValueUsd = vars.variableDebtToken.balanceOf(_manager) * vars.debtPrice;

            vars.denominator = yieldValueUsd > debtValueUsd ? (yieldValueUsd - debtValueUsd) : 1; 
            leverage = yieldValueUsd / vars.denominator;
        }

        Balances memory balances;
        {
            balances = Balances({
                debtBalance: vars.variableDebtToken.balanceOf(_manager),
                yieldBalance: vars.aYieldToken.balanceOf(_manager),
                debtValueUsd: debtValueUsd,
                yieldValueUsd: yieldValueUsd
            });
        }

        (
            uint256 healthFactor,
            uint256 currentLiquidationThreshold,
            int256 positionValueUsd
        ) = getUsdValues(pool, _manager);

        return StrategyDetailed({
            manager: _manager,
            pool: address(pool),
            yieldAsset: yieldAsset,
            debtAsset: debtAsset,
            healthFactor: healthFactor,
            positionValueUsd: positionValueUsd,
            leverage: leverage,
            liquidationThreshold: currentLiquidationThreshold,
            yieldLiquidityRate: vars.yieldReserve.currentLiquidityRate,
            debtVariableBorrowRate: vars.debtReserve.currentVariableBorrowRate,
            yieldSymbol: IERC20Metadata(yieldAsset).symbol(),
            debtSymbol: IERC20Metadata(debtAsset).symbol(),
            balances: balances
        });
    }


    function getUsdValues(IPool pool, address _manager) public view returns (
        uint256 healthFactor, 
        uint256 currentLiquidationThreshold,
        int256 positionValueUsd
    ) {
        (
            uint256 _totalCollateralBase,
            uint256 _totalDebtBase,
            ,
            uint256 _currentLiquidationThreshold,
            ,
            uint256 _healthFactor
        ) = pool.getUserAccountData(_manager);

        positionValueUsd = int256(_totalCollateralBase) - int256(_totalDebtBase);
        healthFactor = _healthFactor;
        currentLiquidationThreshold = _currentLiquidationThreshold;
    }
}