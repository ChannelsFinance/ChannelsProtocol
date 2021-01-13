pragma solidity ^0.5.16;

import "./CHT.sol";

/**
 * @title Channels's Maximillion Contract
 * @author Channels
 */
contract Maximillion {
    /**
     * @notice The default cHT market to repay in
     */
    CHT public cHT;

    /**
     * @notice Construct a Maximillion to repay max in a CHT market
     */
    constructor(CHT cHT_) public {
        cHT = cHT_;
    }

    /**
     * @notice msg.sender sends HT to repay an account's borrow in the cHT market
     * @dev The provided HT is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, cHT);
    }

    /**
     * @notice msg.sender sends HT to repay an account's borrow in a cHT market
     * @dev The provided HT is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param cHT_ The address of the cHT contract to repay in
     */
    function repayBehalfExplicit(address borrower, CHT cHT_) public payable {
        uint received = msg.value;
        uint borrows = cHT_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            cHT_.repayBorrowBehalf.value(borrows)(borrower);
            msg.sender.transfer(received - borrows);
        } else {
            cHT_.repayBorrowBehalf.value(received)(borrower);
        }
    }
}
