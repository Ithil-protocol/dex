// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.17;

import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Token } from "./Token.sol";

contract Pool {
    using SafeERC20 for ERC20;
    using SafeERC20 for Token;
    using Math for uint256;

    // We model makers as a circular doubly linked list with zero as first and last element
    // This facilitates insertion and deletion of orders making the process gas efficient
    struct Order {
        address offerer;
        uint256 underlyingAmount;
        uint256 staked;
        uint256 previous;
        uint256 next;
    }

    // Mapping from higher to lower
    // By convention, priceLevels[0] is the highest bid;
    mapping(uint256 => uint256) public priceLevels;

    // Makers provide underlying and get accounting after match
    // Takers sell accounting and get underlying immediately
    ERC20 public immutable accounting;
    ERC20 public immutable underlying;

    // the accounting token decimals (stored to save gas);
    uint256 public immutable priceResolution;

    // The minimum spacing percentage between prices, 1e4 corresponding to 100%
    // lower values allow for a more fluid price but frontrunning is exacerbated and staking less useful
    // higher values make token staking useful and frontrunning exploit less feasible
    // but makers must choose between more stringent bids
    // lower values are indicated for stable pairs
    // higher vlaues are indicated for more volatile pairs
    uint16 public immutable tick;

    Token public dexToken;
    // id of the order to access its data, by price
    mapping(uint256 => uint256) public id;
    // orders[price][id]
    mapping(uint256 => mapping(uint256 => Order)) public orders;

    event OrderCreated(address indexed offerer, uint256 index, uint256 amount, uint256 price);
    event OrderFulfilled(
        address indexed offerer,
        address indexed fulfiller,
        uint256 accountingToTransfer,
        uint256 amount,
        uint256 price
    );
    event OrderCancelled(address indexed offerer, uint256 index, uint256 price, uint256 underlyingToTransfer);

    error RestrictedToOwner();
    error IncorrectTickSpacing();
    error NullAmount();
    error WrongIndex();

    constructor(address _underlying, address _accounting, address _dexToken, uint16 _tick) {
        accounting = ERC20(_accounting);
        priceResolution = 10**accounting.decimals();

        underlying = ERC20(_underlying);
        dexToken = Token(_dexToken);
        tick = _tick;
    }

    // Example WETH / USDC, maker USDC, taker WETH
    // priceResolution = 1e18 (decimals of WETH)
    // Price = 1753.54 WETH/USDC -> 1753540000 (it has USDC decimals)
    // Sell 2.3486 WETH -> accountingAmount = 2348600000000000000
    // underlyingOut = 2348600000000000000 * 1753540000 / 1e18 = 4118364044 -> 4,118.364044 USDC
    function convertToUnderlying(uint256 accountingAmount, uint256 price) public view returns (uint256) {
        return accountingAmount.mulDiv(price, priceResolution, Math.Rounding.Down);
    }

    function convertToAccounting(uint256 underlyingAmount, uint256 price) public view returns (uint256) {
        return underlyingAmount.mulDiv(priceResolution, price, Math.Rounding.Up);
    }

    function _checkSpacing(uint256 lower, uint256 higher) internal view returns (bool) {
        return lower == 0 || higher >= lower.mulDiv(tick + 10000, 10000, Math.Rounding.Up);
    }

    function _addNode(uint256 price, uint256 amount, uint256 staked, address maker) internal {
        uint256 higherPrice = 0;
        while (priceLevels[higherPrice] > price) {
            higherPrice = priceLevels[higherPrice];
        }

        if (priceLevels[higherPrice] < price) {
            if (
                !_checkSpacing(priceLevels[higherPrice], price) ||
                (!_checkSpacing(price, higherPrice) && higherPrice != 0)
            ) revert IncorrectTickSpacing();

            priceLevels[price] = priceLevels[higherPrice];
            priceLevels[higherPrice] = price;
        }

        // The "next" index of the last order is 0
        id[price]++;
        uint256 previous = 0;
        uint256 next = orders[price][0].next;

        // Get the latest position such that staked <= orders[price][previous].staked
        while (staked <= orders[price][next].staked && next != 0) {
            previous = next;
            next = orders[price][next].next;
        }

        orders[price][id[price]] = Order(maker, amount, staked, previous, next);
        // The "next" index of the previous node is now id[price] (already bumped by 1)
        orders[price][previous].next = id[price];
        // The "previous" index of the 0 node is now id[price]
        orders[price][next].previous = id[price];
    }

    function _deleteNode(uint256 price, uint256 index, bool burn) internal {
        Order memory toDelete = orders[price][index];

        orders[price][toDelete.previous].next = toDelete.next;
        orders[price][toDelete.next].previous = toDelete.previous;

        if (toDelete.staked > 0 && burn) dexToken.burn(toDelete.staked);
        delete orders[price][index];
    }

    // Add a node to the list
    function createOrder(uint256 amount, uint256 staked, uint256 price) external {
        if (amount == 0 || price == 0) revert NullAmount();

        underlying.safeTransferFrom(msg.sender, address(this), amount);
        if (staked > 0) dexToken.safeTransferFrom(msg.sender, address(this), staked);
        _addNode(price, amount, staked, msg.sender);

        emit OrderCreated(msg.sender, id[price], amount, price);
    }

    function cancelOrder(uint256 index, uint256 price) external {
        Order memory order = orders[price][index];
        if (order.offerer != msg.sender) revert RestrictedToOwner();

        _deleteNode(price, index, false);

        dexToken.safeTransfer(msg.sender, order.staked);
        underlying.safeTransfer(msg.sender, order.underlyingAmount);

        emit OrderCancelled(order.offerer, index, price, order.underlyingAmount);
    }

    // amount is always of underlying currency
    function fulfillOrder(uint256 amount, address receiver) external returns (uint256, uint256) {
        uint256 accountingToPay = 0;
        uint256 initialAmount = amount;
        while (amount > 0 && priceLevels[0] != 0) {
            (uint256 payStep, uint256 underlyingReceived) = fulfillOrderByPrice(amount, priceLevels[0], receiver);
            // underlyingPaid <= amount
            unchecked {
                amount -= underlyingReceived;
            }
            accountingToPay += payStep;
            if (amount > 0) priceLevels[0] = priceLevels[priceLevels[0]];
        }

        return (accountingToPay, initialAmount - amount);
    }

    // amount is always of underlying currency
    function fulfillOrderByPrice(uint256 amount, uint256 price, address receiver) internal returns (uint256, uint256) {
        uint256 cursor = orders[price][0].next;
        Order memory order = orders[price][cursor];

        uint256 accountingToTransfer = 0;
        uint256 initialAmount = amount;

        while (amount >= order.underlyingAmount) {
            uint256 toTransfer = convertToAccounting(order.underlyingAmount, price);
            accounting.safeTransferFrom(msg.sender, order.offerer, toTransfer);
            accountingToTransfer += toTransfer;
            _deleteNode(price, cursor, true);
            amount -= order.underlyingAmount;
            cursor = order.next;
            // in case the next is zero, we reached the end of all orders
            if (cursor == 0) break;
            order = orders[price][cursor];
        }

        if (amount > 0 && cursor != 0) {
            uint256 toTransfer = convertToAccounting(amount, price);
            accounting.safeTransferFrom(msg.sender, order.offerer, toTransfer);
            accountingToTransfer += toTransfer;
            orders[price][cursor].underlyingAmount -= amount;

            amount = 0;
        }

        underlying.safeTransfer(receiver, initialAmount - amount);

        emit OrderFulfilled(order.offerer, msg.sender, accountingToTransfer, initialAmount - amount, price);

        return (accountingToTransfer, initialAmount - amount);
    }

    // amount is always of underlying currency
    function previewTake(uint256 amount) external view returns (uint256, uint256) {
        uint256 accountingToPay = 0;
        uint256 initialAmount = amount;
        uint256 price = priceLevels[0];
        while (amount > 0 && price != 0) {
            (uint256 payStep, uint256 underlyingReceived) = previewTakeByPrice(amount, priceLevels[0]);
            // underlyingPaid <= amount
            unchecked {
                amount -= underlyingReceived;
            }
            accountingToPay += payStep;
            price = priceLevels[price];
        }

        return (accountingToPay, initialAmount - amount);
    }

    // View function to calculate how much accounting the taker needs to take amount
    function previewTakeByPrice(uint256 amount, uint256 price) internal view returns (uint256, uint256) {
        uint256 cursor = orders[price][0].next;
        Order memory order = orders[price][cursor];

        uint256 accountingToTransfer = 0;
        uint256 initialAmount = amount;
        while (amount >= order.underlyingAmount) {
            uint256 toTransfer = convertToAccounting(order.underlyingAmount, price);
            accountingToTransfer += toTransfer;
            amount -= order.underlyingAmount;
            cursor = order.next;
            // in case the next is zero, we reached the end of all orders
            if (cursor == 0) break;
            order = orders[price][cursor];
        }

        if (amount > 0 && cursor != 0) {
            uint256 toTransfer = convertToAccounting(amount, price);
            accountingToTransfer += toTransfer;
            amount = 0;
        }

        return (accountingToTransfer, initialAmount - amount);
    }

    // View function to calculate how much accounting and underlying a redeem would return
    function previewRedeem(uint256 index, uint256 price) external view returns (uint256) {
        return orders[price][index].underlyingAmount;
    }
}
