# STX Options Trading Platform

A decentralized peer-to-peer marketplace for creating, trading, and settling STX options contracts on the Stacks blockchain.

## Overview

This smart contract enables users to write and purchase both call and put options with full collateralization. All option positions are fully backed by locked collateral to ensure settlement guarantees. The platform implements automated expiration settlement, transfer mechanisms, and platform fee collection.

## Features

- **Option Creation**: Write fully collateralized call and put options
- **Peer-to-Peer Trading**: Buy and transfer options between users
- **Automated Settlement**: Exercise options or settle expired contracts
- **Collateral Management**: Deposit, lock, and withdraw collateral
- **Platform Fees**: Configurable fee structure for platform sustainability
- **Emergency Controls**: Pause trading and emergency shutdown capabilities
- **Price Oracle Integration**: Update and retrieve price feeds for settlement

## Contract Architecture

### Option Types

- **Call Options** (type: 1): Right to buy STX at strike price
- **Put Options** (type: 2): Right to sell STX at strike price

### Option Status

- **Active** (1): Option is tradeable and exercisable
- **Exercised** (2): Option has been exercised by holder
- **Expired** (3): Option has passed expiration without exercise

## Configuration Parameters

### Limits

- **Minimum Expiration**: 144 blocks (approximately 24 hours)
- **Maximum Expiration**: 52,560 blocks (approximately 1 year)
- **Minimum Strike Price**: 1,000 micro-STX (0.001 STX)
- **Maximum Strike Price**: 100,000,000 micro-STX (100 STX)
- **Minimum Contract Size**: 1 unit
- **Maximum Contract Size**: 1,000,000 units

### Fees

- **Platform Fee**: Configurable in basis points (default: 100 = 1%)
- **Maximum Fee**: 1,000 basis points (10%)

## Core Functions

### Collateral Management

#### deposit-collateral
```clarity
(deposit-collateral (amount uint))
```
Deposits STX as collateral for writing options. Collateral is held by the contract and tracked in user accounts.

**Parameters:**
- `amount`: Amount of STX to deposit (in micro-STX)

**Returns:** `(ok true)` on success

#### withdraw-collateral
```clarity
(withdraw-collateral (amount uint))
```
Withdraws unlocked collateral from user account. Only available collateral (not locked in active options) can be withdrawn.

**Parameters:**
- `amount`: Amount of STX to withdraw (in micro-STX)

**Returns:** `(ok true)` on success

### Option Creation

#### create-option
```clarity
(create-option (strike-price uint) (premium-amount uint) (expiration-block-height uint) (option-type uint) (contract-size uint))
```
Creates a new option contract with full parameter validation and collateral locking. The caller becomes the option writer.

**Parameters:**
- `strike-price`: Exercise price in micro-STX
- `premium-amount`: Price for buying the option in micro-STX
- `expiration-block-height`: Block height when option expires
- `option-type`: 1 for call, 2 for put
- `contract-size`: Number of units covered by option

**Returns:** `(ok option-id)` with the new option identifier

**Collateral Requirements:**
- Call options: `contract-size * strike-price`
- Put options: `contract-size * strike-price`

### Trading Functions

#### buy-option
```clarity
(buy-option (option-id uint))
```
Purchases an option from the writer by paying the premium plus platform fee. The option must be active and currently held by the writer.

**Parameters:**
- `option-id`: Identifier of the option to purchase

**Returns:** `(ok true)` on success

**Payment Breakdown:**
- Premium (minus platform fee) goes to writer
- Platform fee goes to fee collection address

#### transfer-option
```clarity
(transfer-option (option-id uint) (new-holder principal))
```
Transfers option ownership from current holder to a new holder. Only the current holder can transfer.

**Parameters:**
- `option-id`: Identifier of the option to transfer
- `new-holder`: Principal address of the new holder

**Returns:** `(ok true)` on success

### Exercise Functions

#### exercise-call-option
```clarity
(exercise-call-option (option-id uint))
```
Exercises a call option by paying the strike price to the writer. Releases locked collateral back to the writer.

**Parameters:**
- `option-id`: Identifier of the call option to exercise

**Returns:** `(ok true)` on success

**Requirements:**
- Caller must be option holder
- Option must be active (not expired or exercised)
- Payment required: `strike-price * contract-size`

#### exercise-put-option
```clarity
(exercise-put-option (option-id uint))
```
Exercises a put option by receiving the strike price from locked collateral. Remaining collateral is returned to the writer.

**Parameters:**
- `option-id`: Identifier of the put option to exercise

**Returns:** `(ok true)` on success

**Requirements:**
- Caller must be option holder
- Option must be active (not expired or exercised)
- Holder receives: `strike-price * contract-size`

#### settle-expired-option
```clarity
(settle-expired-option (option-id uint))
```
Settles an expired option and releases locked collateral back to the writer. Can be called by anyone after expiration.

**Parameters:**
- `option-id`: Identifier of the expired option

**Returns:** `(ok true)` on success

**Requirements:**
- Current block height must be at or past expiration
- Option must be in active status

### Read-Only Functions

#### get-option-details
```clarity
(get-option-details (option-id uint))
```
Retrieves complete option contract details.

**Returns:** Option data including writer, holder, strike price, expiration, status, and collateral information

#### get-user-collateral
```clarity
(get-user-collateral (user-address principal))
```
Returns collateral balance information for a user.

**Returns:** Tuple with `locked-collateral` and `available-collateral`

#### get-platform-status
```clarity
(get-platform-status)
```
Provides current platform configuration and state.

**Returns:** Tuple with trading status, emergency shutdown status, fee rate, and next option ID

#### get-price-feed
```clarity
(get-price-feed (feed-block-height uint))
```
Fetches oracle price data for a specified block height.

**Returns:** Price feed data including STX price, timestamp, and reporter address

### Administrative Functions

#### pause-trading
```clarity
(pause-trading)
```
Halts all trading operations. Only callable by contract owner.

#### resume-trading
```clarity
(resume-trading)
```
Resumes trading operations after pause. Only callable by contract owner.

#### set-platform-fee
```clarity
(set-platform-fee (new-fee-rate uint))
```
Updates platform fee rate in basis points. Maximum 1,000 (10%). Only callable by contract owner.

#### trigger-emergency-shutdown
```clarity
(trigger-emergency-shutdown)
```
Activates emergency shutdown and halts all operations. Only callable by contract owner.

#### update-price-oracle
```clarity
(update-price-oracle (stx-price uint))
```
Updates oracle price feed for settlement calculations.

## Error Codes

### Access Control Errors
- `u1000`: Unauthorized access
- `u1007`: Not option holder
- `u1012`: Not option writer

### Option State Errors
- `u1001`: Invalid option identifier
- `u1002`: Option expired
- `u1003`: Option already exercised
- `u1013`: Option not found

### Collateral Errors
- `u1004`: Insufficient balance
- `u1011`: Insufficient collateral
- `u1016`: Collateral locked

### Input Validation Errors
- `u1005`: Invalid expiration
- `u1006`: Invalid strike price
- `u1008`: Invalid premium
- `u1009`: Invalid contract size
- `u1010`: Unsupported option type
- `u1015`: Invalid price

### Platform State Errors
- `u1014`: Contract paused

## Usage Examples

### Writing a Call Option

1. Deposit collateral:
```clarity
(contract-call? .options-platform deposit-collateral u10000000)
```

2. Create call option:
```clarity
(contract-call? .options-platform create-option 
  u5000000    ;; strike price: 5 STX
  u100000     ;; premium: 0.1 STX
  u52704      ;; expiration: ~1 year from now
  u1          ;; call option
  u2)         ;; contract size: 2 units
```

### Buying and Exercising an Option

1. Buy option:
```clarity
(contract-call? .options-platform buy-option u1)
```

2. Exercise call option:
```clarity
(contract-call? .options-platform exercise-call-option u1)
```

### Settling Expired Options

After expiration, anyone can settle:
```clarity
(contract-call? .options-platform settle-expired-option u1)
```

## Security Considerations

- All options require full collateralization before creation
- Collateral is locked in the contract until exercise or expiration
- Platform includes emergency pause and shutdown mechanisms
- Only option holders can exercise their options
- Only option writers can receive their collateral back after expiration