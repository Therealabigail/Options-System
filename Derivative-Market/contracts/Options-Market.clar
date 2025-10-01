;; STX Options Trading Platform Smart Contract
;; A decentralized peer-to-peer marketplace for creating, trading, and settling STX options contracts
;; Enables users to write and purchase both call and put options with full collateralization
;; Implements automated expiration settlement, transfer mechanisms, and platform fee collection
;; All option positions are fully backed by locked collateral to ensure settlement guarantees

(define-constant contract-owner tx-sender)

;; Error codes for access control and authorization failures
(define-constant ERR-UNAUTHORIZED-ACCESS (err u1000))
(define-constant ERR-NOT-OPTION-HOLDER (err u1007))
(define-constant ERR-NOT-OPTION-WRITER (err u1012))

;; Error codes for option state and lifecycle validation
(define-constant ERR-INVALID-OPTION-IDENTIFIER (err u1001))
(define-constant ERR-OPTION-EXPIRED (err u1002))
(define-constant ERR-OPTION-ALREADY-EXERCISED (err u1003))
(define-constant ERR-OPTION-NOT-FOUND (err u1013))

;; Error codes for collateral and balance management
(define-constant ERR-INSUFFICIENT-BALANCE (err u1004))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u1011))
(define-constant ERR-COLLATERAL-LOCKED (err u1016))

;; Error codes for input parameter validation
(define-constant ERR-INVALID-EXPIRATION (err u1005))
(define-constant ERR-INVALID-STRIKE-PRICE (err u1006))
(define-constant ERR-INVALID-PREMIUM (err u1008))
(define-constant ERR-INVALID-CONTRACT-SIZE (err u1009))
(define-constant ERR-UNSUPPORTED-OPTION-TYPE (err u1010))
(define-constant ERR-INVALID-PRICE (err u1015))

;; Error codes for platform state
(define-constant ERR-CONTRACT-PAUSED (err u1014))

;; Option type identifiers for call and put contracts
(define-constant option-type-call u1)
(define-constant option-type-put u2)

;; Lifecycle status indicators for option contracts
(define-constant status-active u1)
(define-constant status-exercised u2)
(define-constant status-expired u3)

;; Minimum time before expiration in blocks, approximately 24 hours
(define-constant minimum-expiration-blocks u144)

;; Maximum time until expiration in blocks, approximately 1 year
(define-constant maximum-expiration-blocks u52560)

;; Minimum allowed strike price in micro-STX, equals 0.001 STX
(define-constant minimum-strike-price u1000)

;; Maximum allowed strike price in micro-STX, equals 100 STX
(define-constant maximum-strike-price u100000000)

;; Minimum contract size in units of underlying asset
(define-constant minimum-contract-size u1)

;; Maximum contract size in units of underlying asset
(define-constant maximum-contract-size u1000000)

;; Controls whether new option creation and trading is allowed
(define-data-var is-trading-paused bool false)

;; Emergency flag that halts all contract operations
(define-data-var is-emergency-shutdown bool false)

;; Sequential counter for assigning unique identifiers to new options
(define-data-var next-option-id uint u1)

;; Platform fee expressed in basis points where 100 equals 1 percent
(define-data-var platform-fee-basis-points uint u100)

;; Recipient address for collected platform fees
(define-data-var fee-collection-address principal tx-sender)

;; Comprehensive storage for all option contract parameters and state
(define-map option-contracts
  { option-id: uint }
  {
    writer-address: principal,
    holder-address: principal,
    strike-price: uint,
    premium-amount: uint,
    expiration-block-height: uint,
    option-type: uint,
    contract-status: uint,
    contract-size: uint,
    creation-block-height: uint,
    locked-collateral: uint,
    has-locked-collateral: bool
  }
)

;; Tracks collateral deposits and locked amounts for option writers
(define-map user-collateral-accounts
  { user-address: principal }
  { locked-collateral: uint, available-collateral: uint }
)

;; Oracle price feed storage indexed by block height
(define-map price-oracle-data
  { feed-block-height: uint }
  { stx-price: uint, update-timestamp: uint, reporter-address: principal }
)

;; Validates that an option identifier exists within the valid range
(define-private (is-valid-option-id (option-id uint))
  (and (> option-id u0) (< option-id (var-get next-option-id)))
)

;; Confirms option type is either call or put
(define-private (is-valid-option-type (option-type uint))
  (or (is-eq option-type option-type-call) (is-eq option-type option-type-put))
)

;; Checks if option is unexpired and in active status
(define-private (is-option-active (option-data (tuple 
    (writer-address principal) (holder-address principal) (strike-price uint)
    (premium-amount uint) (expiration-block-height uint) (option-type uint)
    (contract-status uint) (contract-size uint) (creation-block-height uint)
    (locked-collateral uint) (has-locked-collateral bool))))
  (and 
    (< block-height (get expiration-block-height option-data))
    (is-eq (get contract-status option-data) status-active)
  )
)

;; Calculates total collateral required based on option type and parameters
(define-private (calculate-collateral-requirement (option-type uint) (strike-price uint) (contract-size uint))
  (if (is-eq option-type option-type-call)
    (* contract-size strike-price)
    (* contract-size strike-price)
  )
)

;; Computes platform fee amount from premium using current fee rate
(define-private (calculate-platform-fee (premium-amount uint))
  (/ (* premium-amount (var-get platform-fee-basis-points)) u10000)
)

;; Verifies caller is the contract administrator
(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

;; Confirms trading operations are not paused
(define-private (is-trading-active)
  (not (var-get is-trading-paused))
)

;; Allows users to deposit STX as collateral for writing options
(define-public (deposit-collateral (amount uint))
  (begin
    (asserts! (is-trading-active) ERR-CONTRACT-PAUSED)
    (asserts! (> amount u0) ERR-INVALID-PRICE)
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    (let ((current-balance (default-to { locked-collateral: u0, available-collateral: u0 } 
                            (map-get? user-collateral-accounts { user-address: tx-sender }))))
      (map-set user-collateral-accounts
        { user-address: tx-sender }
        { 
          locked-collateral: (get locked-collateral current-balance),
          available-collateral: (+ (get available-collateral current-balance) amount)
        }
      )
    )
    
    (ok true)
  )
)

;; Enables withdrawal of unlocked collateral from user account
(define-public (withdraw-collateral (amount uint))
  (begin
    (asserts! (is-trading-active) ERR-CONTRACT-PAUSED)
    (asserts! (> amount u0) ERR-INVALID-PRICE)
    
    (let ((account-balance (unwrap! (map-get? user-collateral-accounts { user-address: tx-sender }) 
                            ERR-INSUFFICIENT-COLLATERAL)))
      
      (asserts! (>= (get available-collateral account-balance) amount) ERR-INSUFFICIENT-COLLATERAL)
      
      (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
      
      (map-set user-collateral-accounts
        { user-address: tx-sender }
        { 
          locked-collateral: (get locked-collateral account-balance),
          available-collateral: (- (get available-collateral account-balance) amount)
        }
      )
      
      (ok true)
    )
  )
)

;; Retrieves complete option contract details by identifier
(define-read-only (get-option-details (option-id uint))
  (begin
    (asserts! (is-valid-option-id option-id) ERR-INVALID-OPTION-IDENTIFIER)
    (ok (map-get? option-contracts { option-id: option-id }))
  )
)

;; Returns collateral balance information for specified user
(define-read-only (get-user-collateral (user-address principal))
  (map-get? user-collateral-accounts { user-address: user-address })
)

;; Provides current platform configuration and state variables
(define-read-only (get-platform-status)
  {
    is-trading-paused: (var-get is-trading-paused),
    is-emergency-shutdown: (var-get is-emergency-shutdown),
    platform-fee-basis-points: (var-get platform-fee-basis-points),
    next-option-id: (var-get next-option-id)
  }
)

;; Fetches oracle price data for specified block height
(define-read-only (get-price-feed (feed-block-height uint))
  (map-get? price-oracle-data { feed-block-height: feed-block-height })
)

;; Creates new option contract with full parameter validation and collateral locking
(define-public (create-option 
    (strike-price uint)
    (premium-amount uint)
    (expiration-block-height uint)
    (option-type uint)
    (contract-size uint))
  (let ((new-option-id (var-get next-option-id)))
    
    (asserts! (is-trading-active) ERR-CONTRACT-PAUSED)
    (asserts! (and (>= strike-price minimum-strike-price) (<= strike-price maximum-strike-price)) ERR-INVALID-STRIKE-PRICE)
    (asserts! (> premium-amount u0) ERR-INVALID-PREMIUM)
    (asserts! (and (>= contract-size minimum-contract-size) (<= contract-size maximum-contract-size)) ERR-INVALID-CONTRACT-SIZE)
    (asserts! (and 
               (> expiration-block-height (+ block-height minimum-expiration-blocks))
               (< expiration-block-height (+ block-height maximum-expiration-blocks))
              ) ERR-INVALID-EXPIRATION)
    (asserts! (is-valid-option-type option-type) ERR-UNSUPPORTED-OPTION-TYPE)
    
    (let ((required-collateral (calculate-collateral-requirement option-type strike-price contract-size)))
      
      (asserts! (> required-collateral u0) ERR-INSUFFICIENT-COLLATERAL)
      
      (let ((writer-collateral (unwrap! (map-get? user-collateral-accounts { user-address: tx-sender }) 
                                ERR-INSUFFICIENT-COLLATERAL)))
        (asserts! (>= (get available-collateral writer-collateral) required-collateral) ERR-INSUFFICIENT-COLLATERAL)
        
        (map-set user-collateral-accounts
          { user-address: tx-sender }
          { 
            locked-collateral: (+ (get locked-collateral writer-collateral) required-collateral),
            available-collateral: (- (get available-collateral writer-collateral) required-collateral)
          }
        )
      )
      
      (map-set option-contracts
        { option-id: new-option-id }
        {
          writer-address: tx-sender,
          holder-address: tx-sender,
          strike-price: strike-price,
          premium-amount: premium-amount,
          expiration-block-height: expiration-block-height,
          option-type: option-type,
          contract-status: status-active,
          contract-size: contract-size,
          creation-block-height: block-height,
          locked-collateral: required-collateral,
          has-locked-collateral: true
        }
      )
      
      (var-set next-option-id (+ new-option-id u1))
      
      (ok new-option-id)
    )
  )
)

;; Transfers option ownership from current holder to new holder
(define-public (transfer-option (option-id uint) (new-holder principal))
  (begin
    (asserts! (is-trading-active) ERR-CONTRACT-PAUSED)
    (asserts! (is-valid-option-id option-id) ERR-INVALID-OPTION-IDENTIFIER)
    
    (let ((option-data (unwrap! (map-get? option-contracts { option-id: option-id }) 
                        ERR-OPTION-NOT-FOUND)))
      
      (asserts! (is-option-active option-data) ERR-OPTION-EXPIRED)
      (asserts! (is-eq (get holder-address option-data) tx-sender) ERR-NOT-OPTION-HOLDER)
      
      (map-set option-contracts
        { option-id: option-id }
        (merge option-data { holder-address: new-holder })
      )
      
      (ok true)
    )
  )
)

;; Enables purchase of option from writer by paying premium plus platform fee
(define-public (buy-option (option-id uint))
  (begin
    (asserts! (is-trading-active) ERR-CONTRACT-PAUSED)
    (asserts! (is-valid-option-id option-id) ERR-INVALID-OPTION-IDENTIFIER)
    
    (let ((option-data (unwrap! (map-get? option-contracts { option-id: option-id }) 
                        ERR-OPTION-NOT-FOUND))
          (platform-fee (calculate-platform-fee (get premium-amount option-data))))
      
      (asserts! (is-option-active option-data) ERR-OPTION-EXPIRED)
      (asserts! (is-eq (get writer-address option-data) (get holder-address option-data)) ERR-UNAUTHORIZED-ACCESS)
      
      (try! (stx-transfer? (- (get premium-amount option-data) platform-fee) tx-sender (get writer-address option-data)))
      
      (if (> platform-fee u0)
        (try! (stx-transfer? platform-fee tx-sender (var-get fee-collection-address)))
        true
      )
      
      (map-set option-contracts
        { option-id: option-id }
        (merge option-data { holder-address: tx-sender })
      )
      
      (ok true)
    )
  )
)

;; Executes call option by paying strike price and releasing collateral
(define-public (exercise-call-option (option-id uint))
  (begin
    (asserts! (is-trading-active) ERR-CONTRACT-PAUSED)
    (asserts! (is-valid-option-id option-id) ERR-INVALID-OPTION-IDENTIFIER)
    
    (let ((option-data (unwrap! (map-get? option-contracts { option-id: option-id }) 
                        ERR-OPTION-NOT-FOUND))
          (exercise-payment (* (get strike-price option-data) (get contract-size option-data))))
      
      (asserts! (is-option-active option-data) ERR-OPTION-EXPIRED)
      (asserts! (is-eq (get option-type option-data) option-type-call) ERR-UNSUPPORTED-OPTION-TYPE)
      (asserts! (is-eq (get holder-address option-data) tx-sender) ERR-NOT-OPTION-HOLDER)
      
      (try! (stx-transfer? exercise-payment tx-sender (get writer-address option-data)))
      
      (let ((writer-collateral (unwrap! (map-get? user-collateral-accounts { user-address: (get writer-address option-data) }) 
                                ERR-INSUFFICIENT-COLLATERAL)))
        (map-set user-collateral-accounts
          { user-address: (get writer-address option-data) }
          { 
            locked-collateral: (- (get locked-collateral writer-collateral) (get locked-collateral option-data)),
            available-collateral: (+ (get available-collateral writer-collateral) (get locked-collateral option-data))
          }
        )
      )
      
      (map-set option-contracts
        { option-id: option-id }
        (merge option-data { contract-status: status-exercised, has-locked-collateral: false })
      )
      
      (ok true)
    )
  )
)

;; Executes put option by paying holder and releasing remaining collateral
(define-public (exercise-put-option (option-id uint))
  (begin
    (asserts! (is-trading-active) ERR-CONTRACT-PAUSED)
    (asserts! (is-valid-option-id option-id) ERR-INVALID-OPTION-IDENTIFIER)
    
    (let ((option-data (unwrap! (map-get? option-contracts { option-id: option-id }) 
                        ERR-OPTION-NOT-FOUND))
          (payout-amount (* (get strike-price option-data) (get contract-size option-data))))
      
      (asserts! (is-option-active option-data) ERR-OPTION-EXPIRED)
      (asserts! (is-eq (get option-type option-data) option-type-put) ERR-UNSUPPORTED-OPTION-TYPE)
      (asserts! (is-eq (get holder-address option-data) tx-sender) ERR-NOT-OPTION-HOLDER)
      
      (try! (as-contract (stx-transfer? payout-amount tx-sender tx-sender)))
      
      (let ((writer-collateral (unwrap! (map-get? user-collateral-accounts { user-address: (get writer-address option-data) }) 
                                ERR-INSUFFICIENT-COLLATERAL))
            (remaining-collateral (- (get locked-collateral option-data) payout-amount)))
        (map-set user-collateral-accounts
          { user-address: (get writer-address option-data) }
          { 
            locked-collateral: (- (get locked-collateral writer-collateral) (get locked-collateral option-data)),
            available-collateral: (+ (get available-collateral writer-collateral) remaining-collateral)
          }
        )
      )
      
      (map-set option-contracts
        { option-id: option-id }
        (merge option-data { contract-status: status-exercised, has-locked-collateral: false })
      )
      
      (ok true)
    )
  )
)

;; Settles expired options and releases locked collateral back to writer
(define-public (settle-expired-option (option-id uint))
  (begin
    (asserts! (is-valid-option-id option-id) ERR-INVALID-OPTION-IDENTIFIER)
    
    (let ((option-data (unwrap! (map-get? option-contracts { option-id: option-id }) 
                        ERR-OPTION-NOT-FOUND)))
      
      (asserts! (>= block-height (get expiration-block-height option-data)) ERR-UNAUTHORIZED-ACCESS)
      (asserts! (is-eq (get contract-status option-data) status-active) ERR-OPTION-ALREADY-EXERCISED)
      
      (if (get has-locked-collateral option-data)
        (let ((writer-collateral (unwrap! (map-get? user-collateral-accounts { user-address: (get writer-address option-data) }) 
                                  ERR-INSUFFICIENT-COLLATERAL)))
          (map-set user-collateral-accounts
            { user-address: (get writer-address option-data) }
            { 
              locked-collateral: (- (get locked-collateral writer-collateral) (get locked-collateral option-data)),
              available-collateral: (+ (get available-collateral writer-collateral) (get locked-collateral option-data))
            }
          )
        )
        true
      )
      
      (map-set option-contracts
        { option-id: option-id }
        (merge option-data { contract-status: status-expired, has-locked-collateral: false })
      )
      
      (ok true)
    )
  )
)

;; Updates oracle price feed for settlement calculations
(define-public (update-price-oracle (stx-price uint))
  (begin
    (asserts! (> stx-price u0) ERR-INVALID-PRICE)
    
    (map-set price-oracle-data
      { feed-block-height: block-height }
      { stx-price: stx-price, update-timestamp: block-height, reporter-address: tx-sender }
    )
    
    (ok true)
  )
)

;; Halts all trading operations in emergency situations
(define-public (pause-trading)
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED-ACCESS)
    (var-set is-trading-paused true)
    (ok true)
  )
)

;; Resumes trading operations after pause
(define-public (resume-trading)
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED-ACCESS)
    (var-set is-trading-paused false)
    (ok true)
  )
)

;; Updates platform fee rate with maximum limit of 10 percent
(define-public (set-platform-fee (new-fee-rate uint))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED-ACCESS)
    (asserts! (<= new-fee-rate u1000) ERR-INVALID-PRICE)
    (var-set platform-fee-basis-points new-fee-rate)
    (ok true)
  )
)

;; Activates emergency shutdown and halts all operations
(define-public (trigger-emergency-shutdown)
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED-ACCESS)
    (var-set is-emergency-shutdown true)
    (var-set is-trading-paused true)
    (ok true)
  )
)

(begin
  (print "STX Options Trading Platform Initialized")
  (var-get next-option-id)
)