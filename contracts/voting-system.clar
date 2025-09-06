;; Secure Voting System Smart Contract
;; Manages electronic voting with privacy protection and tamper-proof results

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-EXISTS (err u409))
(define-constant ERR-INVALID-INPUT (err u400))
(define-constant ERR-VOTING-CLOSED (err u410))
(define-constant ERR-ALREADY-VOTED (err u411))
(define-constant ERR-NOT-ELIGIBLE (err u412))
(define-constant ERR-ELECTION-NOT-ACTIVE (err u413))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-CANDIDATES u20)
(define-constant MAX-BALLOT-OPTIONS u10)

;; Data structures for elections
(define-map elections
  uint
  {
    election-id: uint,
    title: (string-ascii 100),
    description: (string-ascii 300),
    election-type: (string-ascii 30),
    start-time: uint,
    end-time: uint,
    status: (string-ascii 20),
    creator: principal,
    total-eligible-voters: uint,
    total-votes-cast: uint
  }
)

(define-map candidates
  { election-id: uint, candidate-id: uint }
  {
    name: (string-ascii 100),
    description: (string-ascii 200),
    party: (string-ascii 50),
    vote-count: uint,
    status: (string-ascii 20)
  }
)

(define-map ballot-options
  { election-id: uint, option-id: uint }
  {
    option-text: (string-ascii 200),
    vote-count: uint,
    status: (string-ascii 20)
  }
)

(define-map voter-eligibility
  { election-id: uint, voter: principal }
  {
    eligible: bool,
    registration-time: uint,
    verification-hash: (buff 32),
    district: (string-ascii 50)
  }
)

(define-map vote-records
  { election-id: uint, voter: principal }
  {
    vote-hash: (buff 32),
    timestamp: uint,
    voting-method: (string-ascii 30),
    verified: bool
  }
)

(define-map election-results
  uint
  {
    election-id: uint,
    winner: (optional uint),
    total-valid-votes: uint,
    total-invalid-votes: uint,
    finalized: bool,
    results-hash: (buff 32)
  }
)

(define-map voting-administrators principal bool)
(define-map audit-trail
  uint
  {
    action: (string-ascii 50),
    executor: principal,
    target: principal,
    timestamp: uint,
    election-id: uint,
    details: (string-ascii 200)
  }
)

;; Data variables
(define-data-var next-election-id uint u1)
(define-data-var next-audit-id uint u1)
(define-data-var system-status (string-ascii 20) "ACTIVE")

;; Initialize contract owner as administrator
(map-set voting-administrators CONTRACT-OWNER true)

;; Administrative functions
(define-public (add-voting-administrator (admin principal))
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (default-to false (map-get? voting-administrators tx-sender)))
              ERR-UNAUTHORIZED)
    (map-set voting-administrators admin true)
    (record-audit-action "ADD_ADMIN" admin u0)
    (ok true)
  )
)

(define-public (remove-voting-administrator (admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (not (is-eq admin CONTRACT-OWNER)) ERR-INVALID-INPUT)
    (map-delete voting-administrators admin)
    (record-audit-action "REMOVE_ADMIN" admin u0)
    (ok true)
  )
)

;; Election management functions
(define-public (create-election
  (title (string-ascii 100))
  (description (string-ascii 300))
  (election-type (string-ascii 30))
  (start-time uint)
  (end-time uint)
)
  (let
    (
      (election-id (var-get next-election-id))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (asserts! (default-to false (map-get? voting-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (> start-time current-time) ERR-INVALID-INPUT)
      (asserts! (> end-time start-time) ERR-INVALID-INPUT)
      (asserts! (> (len title) u0) ERR-INVALID-INPUT)
      
      (map-set elections election-id
        {
          election-id: election-id,
          title: title,
          description: description,
          election-type: election-type,
          start-time: start-time,
          end-time: end-time,
          status: "SCHEDULED",
          creator: tx-sender,
          total-eligible-voters: u0,
          total-votes-cast: u0
        }
      )
      
      (var-set next-election-id (+ election-id u1))
      (record-audit-action "CREATE_ELECTION" tx-sender election-id)
      (ok election-id)
    )
  )
)

(define-public (add-candidate
  (election-id uint)
  (candidate-id uint)
  (name (string-ascii 100))
  (description (string-ascii 200))
  (party (string-ascii 50))
)
  (begin
    (asserts! (default-to false (map-get? voting-administrators tx-sender)) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? elections election-id)) ERR-NOT-FOUND)
    (asserts! (is-none (map-get? candidates { election-id: election-id, candidate-id: candidate-id }))
              ERR-ALREADY-EXISTS)
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)
    
    (map-set candidates { election-id: election-id, candidate-id: candidate-id }
      {
        name: name,
        description: description,
        party: party,
        vote-count: u0,
        status: "ACTIVE"
      }
    )
    
    (record-audit-action "ADD_CANDIDATE" tx-sender election-id)
    (ok true)
  )
)

(define-public (register-voter
  (election-id uint)
  (voter principal)
  (verification-hash (buff 32))
  (district (string-ascii 50))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (election-data (unwrap! (map-get? elections election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? voting-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (is-none (map-get? voter-eligibility { election-id: election-id, voter: voter }))
                ERR-ALREADY-EXISTS)
      
      (map-set voter-eligibility { election-id: election-id, voter: voter }
        {
          eligible: true,
          registration-time: current-time,
          verification-hash: verification-hash,
          district: district
        }
      )
      
      (map-set elections election-id
        (merge election-data { total-eligible-voters: (+ (get total-eligible-voters election-data) u1) })
      )
      
      (record-audit-action "REGISTER_VOTER" voter election-id)
      (ok true)
    )
  )
)

(define-public (start-election (election-id uint))
  (let
    (
      (election-data (unwrap! (map-get? elections election-id) ERR-NOT-FOUND))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (asserts! (default-to false (map-get? voting-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status election-data) "SCHEDULED") ERR-INVALID-INPUT)
      (asserts! (>= current-time (get start-time election-data)) ERR-INVALID-INPUT)
      
      (map-set elections election-id
        (merge election-data { status: "ACTIVE" })
      )
      
      (record-audit-action "START_ELECTION" tx-sender election-id)
      (ok true)
    )
  )
)

;; Core voting functions
(define-public (cast-vote
  (election-id uint)
  (candidate-id uint)
  (vote-hash (buff 32))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (election-data (unwrap! (map-get? elections election-id) ERR-NOT-FOUND))
      (voter-eligible (unwrap! (map-get? voter-eligibility { election-id: election-id, voter: tx-sender })
                              ERR-NOT-ELIGIBLE))
      (candidate-data (unwrap! (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
                              ERR-NOT-FOUND))
    )
    (begin
      (asserts! (is-eq (get status election-data) "ACTIVE") ERR-ELECTION-NOT-ACTIVE)
      (asserts! (and (>= current-time (get start-time election-data))
                     (< current-time (get end-time election-data)))
                ERR-VOTING-CLOSED)
      (asserts! (get eligible voter-eligible) ERR-NOT-ELIGIBLE)
      (asserts! (is-none (map-get? vote-records { election-id: election-id, voter: tx-sender }))
                ERR-ALREADY-VOTED)
      
      ;; Record the vote
      (map-set vote-records { election-id: election-id, voter: tx-sender }
        {
          vote-hash: vote-hash,
          timestamp: current-time,
          voting-method: "BLOCKCHAIN",
          verified: true
        }
      )
      
      ;; Update candidate vote count
      (map-set candidates { election-id: election-id, candidate-id: candidate-id }
        (merge candidate-data { vote-count: (+ (get vote-count candidate-data) u1) })
      )
      
      ;; Update election statistics
      (map-set elections election-id
        (merge election-data { total-votes-cast: (+ (get total-votes-cast election-data) u1) })
      )
      
      (record-audit-action "CAST_VOTE" tx-sender election-id)
      (ok true)
    )
  )
)

(define-public (cast-ballot-vote
  (election-id uint)
  (option-id uint)
  (vote-hash (buff 32))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (election-data (unwrap! (map-get? elections election-id) ERR-NOT-FOUND))
      (voter-eligible (unwrap! (map-get? voter-eligibility { election-id: election-id, voter: tx-sender })
                              ERR-NOT-ELIGIBLE))
      (option-data (unwrap! (map-get? ballot-options { election-id: election-id, option-id: option-id })
                           ERR-NOT-FOUND))
    )
    (begin
      (asserts! (is-eq (get status election-data) "ACTIVE") ERR-ELECTION-NOT-ACTIVE)
      (asserts! (and (>= current-time (get start-time election-data))
                     (< current-time (get end-time election-data)))
                ERR-VOTING-CLOSED)
      (asserts! (get eligible voter-eligible) ERR-NOT-ELIGIBLE)
      (asserts! (is-none (map-get? vote-records { election-id: election-id, voter: tx-sender }))
                ERR-ALREADY-VOTED)
      
      ;; Record the vote
      (map-set vote-records { election-id: election-id, voter: tx-sender }
        {
          vote-hash: vote-hash,
          timestamp: current-time,
          voting-method: "BALLOT",
          verified: true
        }
      )
      
      ;; Update option vote count
      (map-set ballot-options { election-id: election-id, option-id: option-id }
        (merge option-data { vote-count: (+ (get vote-count option-data) u1) })
      )
      
      ;; Update election statistics
      (map-set elections election-id
        (merge election-data { total-votes-cast: (+ (get total-votes-cast election-data) u1) })
      )
      
      (record-audit-action "CAST_BALLOT_VOTE" tx-sender election-id)
      (ok true)
    )
  )
)

(define-public (end-election (election-id uint))
  (let
    (
      (election-data (unwrap! (map-get? elections election-id) ERR-NOT-FOUND))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (asserts! (default-to false (map-get? voting-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status election-data) "ACTIVE") ERR-INVALID-INPUT)
      (asserts! (>= current-time (get end-time election-data)) ERR-INVALID-INPUT)
      
      (map-set elections election-id
        (merge election-data { status: "ENDED" })
      )
      
      (record-audit-action "END_ELECTION" tx-sender election-id)
      (ok true)
    )
  )
)

(define-public (finalize-results
  (election-id uint)
  (winner (optional uint))
  (results-hash (buff 32))
)
  (let
    (
      (election-data (unwrap! (map-get? elections election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? voting-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status election-data) "ENDED") ERR-INVALID-INPUT)
      
      (map-set election-results election-id
        {
          election-id: election-id,
          winner: winner,
          total-valid-votes: (get total-votes-cast election-data),
          total-invalid-votes: u0,
          finalized: true,
          results-hash: results-hash
        }
      )
      
      (map-set elections election-id
        (merge election-data { status: "FINALIZED" })
      )
      
      (record-audit-action "FINALIZE_RESULTS" tx-sender election-id)
      (ok true)
    )
  )
)

;; Read-only functions
(define-read-only (get-election-info (election-id uint))
  (map-get? elections election-id)
)

(define-read-only (get-candidate-info
  (election-id uint)
  (candidate-id uint)
)
  (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
)

(define-read-only (get-ballot-option
  (election-id uint)
  (option-id uint)
)
  (map-get? ballot-options { election-id: election-id, option-id: option-id })
)

(define-read-only (has-voted
  (election-id uint)
  (voter principal)
)
  (is-some (map-get? vote-records { election-id: election-id, voter: voter }))
)

(define-read-only (is-eligible-voter
  (election-id uint)
  (voter principal)
)
  (match (map-get? voter-eligibility { election-id: election-id, voter: voter })
    eligibility-data (get eligible eligibility-data)
    false
  )
)

(define-read-only (get-election-results (election-id uint))
  (map-get? election-results election-id)
)

(define-read-only (is-voting-administrator (user principal))
  (default-to false (map-get? voting-administrators user))
)

(define-read-only (get-vote-record
  (election-id uint)
  (voter principal)
)
  (map-get? vote-records { election-id: election-id, voter: voter })
)

(define-read-only (get-audit-record (audit-id uint))
  (map-get? audit-trail audit-id)
)

(define-read-only (get-system-status)
  (var-get system-status)
)

;; Private helper functions
(define-private (record-audit-action
  (action (string-ascii 50))
  (target principal)
  (election-id uint)
)
  (let
    (
      (audit-id (var-get next-audit-id))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (map-set audit-trail audit-id
        {
          action: action,
          executor: tx-sender,
          target: target,
          timestamp: current-time,
          election-id: election-id,
          details: ""
        }
      )
      (var-set next-audit-id (+ audit-id u1))
      audit-id
    )
  )
)

;; Ballot option management
(define-public (add-ballot-option
  (election-id uint)
  (option-id uint)
  (option-text (string-ascii 200))
)
  (begin
    (asserts! (default-to false (map-get? voting-administrators tx-sender)) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? elections election-id)) ERR-NOT-FOUND)
    (asserts! (is-none (map-get? ballot-options { election-id: election-id, option-id: option-id }))
              ERR-ALREADY-EXISTS)
    (asserts! (> (len option-text) u0) ERR-INVALID-INPUT)
    
    (map-set ballot-options { election-id: election-id, option-id: option-id }
      {
        option-text: option-text,
        vote-count: u0,
        status: "ACTIVE"
      }
    )
    
    (record-audit-action "ADD_BALLOT_OPTION" tx-sender election-id)
    (ok true)
  )
)

;; Emergency functions
(define-public (suspend-election (election-id uint))
  (let
    (
      (election-data (unwrap! (map-get? elections election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
      
      (map-set elections election-id
        (merge election-data { status: "SUSPENDED" })
      )
      
      (record-audit-action "SUSPEND_ELECTION" tx-sender election-id)
      (ok true)
    )
  )
)

(define-public (set-system-status (new-status (string-ascii 20)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set system-status new-status)
    (record-audit-action "SET_SYSTEM_STATUS" tx-sender u0)
    (ok true)
  )
)
