;; Election Registry Smart Contract
;; Manages election lifecycle, registry, and administrative oversight

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-EXISTS (err u409))
(define-constant ERR-INVALID-INPUT (err u400))
(define-constant ERR-INVALID-STATE (err u402))
(define-constant ERR-EXPIRED (err u410))
(define-constant ERR-ACCESS-DENIED (err u403))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-ELECTIONS-PER-PERIOD u50)
(define-constant REGISTRATION-PERIOD u86400) ;; 24 hours in seconds

;; Data structures
(define-map registry-administrators principal bool)
(define-map election-registry
  uint
  {
    election-id: uint,
    title: (string-ascii 100),
    description: (string-ascii 300),
    election-type: (string-ascii 30),
    jurisdiction: (string-ascii 50),
    registration-start: uint,
    registration-end: uint,
    voting-start: uint,
    voting-end: uint,
    status: (string-ascii 20),
    creator: principal,
    minimum-age: uint,
    required-credentials: (list 5 (string-ascii 50))
  }
)

(define-map election-statistics
  uint
  {
    election-id: uint,
    total-registered-voters: uint,
    total-candidates: uint,
    total-votes-cast: uint,
    participation-rate: uint,
    results-published: bool,
    certification-status: (string-ascii 30)
  }
)

(define-map voter-registration-requests
  { election-id: uint, voter: principal }
  {
    request-time: uint,
    approval-status: (string-ascii 20),
    approver: (optional principal),
    verification-documents: (list 3 (buff 32)),
    district: (string-ascii 50),
    demographic-data: (string-ascii 200)
  }
)

(define-map election-officials
  { election-id: uint, official: principal }
  {
    role: (string-ascii 30),
    appointment-time: uint,
    appointer: principal,
    status: (string-ascii 20),
    jurisdiction: (string-ascii 50)
  }
)

(define-map election-districts
  { election-id: uint, district-id: (string-ascii 50) }
  {
    district-name: (string-ascii 100),
    population: uint,
    registered-voters: uint,
    polling-locations: uint,
    district-official: (optional principal)
  }
)

(define-map certification-records
  uint
  {
    election-id: uint,
    certifier: principal,
    certification-date: uint,
    certification-status: (string-ascii 30),
    audit-results: (string-ascii 300),
    public-hash: (buff 32)
  }
)

(define-map registry-events
  uint
  {
    event-type: (string-ascii 50),
    election-id: uint,
    actor: principal,
    timestamp: uint,
    details: (string-ascii 200),
    impact-level: (string-ascii 20)
  }
)

;; Data variables
(define-data-var next-election-registry-id uint u1)
(define-data-var next-event-id uint u1)
(define-data-var registry-status (string-ascii 20) "ACTIVE")
(define-data-var total-elections uint u0)
(define-data-var total-registered-voters uint u0)

;; Initialize contract owner as administrator
(map-set registry-administrators CONTRACT-OWNER true)

;; Administrative functions
(define-public (add-registry-administrator (admin principal))
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (default-to false (map-get? registry-administrators tx-sender)))
              ERR-UNAUTHORIZED)
    (map-set registry-administrators admin true)
    (record-registry-event "ADD_ADMIN" u0 admin "LOW")
    (ok true)
  )
)

(define-public (remove-registry-administrator (admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (not (is-eq admin CONTRACT-OWNER)) ERR-INVALID-INPUT)
    (map-delete registry-administrators admin)
    (record-registry-event "REMOVE_ADMIN" u0 admin "HIGH")
    (ok true)
  )
)

;; Election registration and management
(define-public (register-election
  (title (string-ascii 100))
  (description (string-ascii 300))
  (election-type (string-ascii 30))
  (jurisdiction (string-ascii 50))
  (registration-start uint)
  (registration-end uint)
  (voting-start uint)
  (voting-end uint)
  (minimum-age uint)
  (required-credentials (list 5 (string-ascii 50)))
)
  (let
    (
      (election-id (var-get next-election-registry-id))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (> registration-start current-time) ERR-INVALID-INPUT)
      (asserts! (> registration-end registration-start) ERR-INVALID-INPUT)
      (asserts! (> voting-start registration-end) ERR-INVALID-INPUT)
      (asserts! (> voting-end voting-start) ERR-INVALID-INPUT)
      (asserts! (> (len title) u0) ERR-INVALID-INPUT)
      (asserts! (>= minimum-age u18) ERR-INVALID-INPUT)
      
      (map-set election-registry election-id
        {
          election-id: election-id,
          title: title,
          description: description,
          election-type: election-type,
          jurisdiction: jurisdiction,
          registration-start: registration-start,
          registration-end: registration-end,
          voting-start: voting-start,
          voting-end: voting-end,
          status: "SCHEDULED",
          creator: tx-sender,
          minimum-age: minimum-age,
          required-credentials: required-credentials
        }
      )
      
      (map-set election-statistics election-id
        {
          election-id: election-id,
          total-registered-voters: u0,
          total-candidates: u0,
          total-votes-cast: u0,
          participation-rate: u0,
          results-published: false,
          certification-status: "PENDING"
        }
      )
      
      (var-set next-election-registry-id (+ election-id u1))
      (var-set total-elections (+ (var-get total-elections) u1))
      (record-registry-event "REGISTER_ELECTION" election-id tx-sender "HIGH")
      (ok election-id)
    )
  )
)

(define-public (update-election-status
  (election-id uint)
  (new-status (string-ascii 20))
)
  (let
    (
      (election-data (unwrap! (map-get? election-registry election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
      
      (map-set election-registry election-id
        (merge election-data { status: new-status })
      )
      
      (record-registry-event "UPDATE_STATUS" election-id tx-sender "MEDIUM")
      (ok true)
    )
  )
)

;; Voter registration management
(define-public (request-voter-registration
  (election-id uint)
  (verification-documents (list 3 (buff 32)))
  (district (string-ascii 50))
  (demographic-data (string-ascii 200))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (election-data (unwrap! (map-get? election-registry election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (and (>= current-time (get registration-start election-data))
                     (< current-time (get registration-end election-data)))
                ERR-EXPIRED)
      (asserts! (is-none (map-get? voter-registration-requests { election-id: election-id, voter: tx-sender }))
                ERR-ALREADY-EXISTS)
      
      (map-set voter-registration-requests { election-id: election-id, voter: tx-sender }
        {
          request-time: current-time,
          approval-status: "PENDING",
          approver: none,
          verification-documents: verification-documents,
          district: district,
          demographic-data: demographic-data
        }
      )
      
      (record-registry-event "VOTER_REGISTRATION_REQUEST" election-id tx-sender "LOW")
      (ok true)
    )
  )
)

(define-public (approve-voter-registration
  (election-id uint)
  (voter principal)
  (approved bool)
)
  (let
    (
      (registration-data (unwrap! (map-get? voter-registration-requests { election-id: election-id, voter: voter })
                                 ERR-NOT-FOUND))
      (stats-data (unwrap! (map-get? election-statistics election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get approval-status registration-data) "PENDING") ERR-INVALID-STATE)
      
      (map-set voter-registration-requests { election-id: election-id, voter: voter }
        (merge registration-data { 
          approval-status: (if approved "APPROVED" "REJECTED"),
          approver: (some tx-sender)
        })
      )
      
      (if approved
        (begin
          (map-set election-statistics election-id
            (merge stats-data { total-registered-voters: (+ (get total-registered-voters stats-data) u1) })
          )
          (var-set total-registered-voters (+ (var-get total-registered-voters) u1))
        )
        true
      )
      
      (record-registry-event "VOTER_APPROVAL" election-id voter "MEDIUM")
      (ok true)
    )
  )
)

;; Election officials management
(define-public (appoint-election-official
  (election-id uint)
  (official principal)
  (role (string-ascii 30))
  (jurisdiction (string-ascii 50))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (is-some (map-get? election-registry election-id)) ERR-NOT-FOUND)
      (asserts! (is-none (map-get? election-officials { election-id: election-id, official: official }))
                ERR-ALREADY-EXISTS)
      
      (map-set election-officials { election-id: election-id, official: official }
        {
          role: role,
          appointment-time: current-time,
          appointer: tx-sender,
          status: "ACTIVE",
          jurisdiction: jurisdiction
        }
      )
      
      (record-registry-event "APPOINT_OFFICIAL" election-id official "HIGH")
      (ok true)
    )
  )
)

(define-public (remove-election-official
  (election-id uint)
  (official principal)
)
  (let
    (
      (official-data (unwrap! (map-get? election-officials { election-id: election-id, official: official })
                             ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
      
      (map-set election-officials { election-id: election-id, official: official }
        (merge official-data { status: "REMOVED" })
      )
      
      (record-registry-event "REMOVE_OFFICIAL" election-id official "HIGH")
      (ok true)
    )
  )
)

;; District management
(define-public (register-district
  (election-id uint)
  (district-id (string-ascii 50))
  (district-name (string-ascii 100))
  (population uint)
  (polling-locations uint)
  (district-official (optional principal))
)
  (begin
    (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? election-registry election-id)) ERR-NOT-FOUND)
    (asserts! (is-none (map-get? election-districts { election-id: election-id, district-id: district-id }))
              ERR-ALREADY-EXISTS)
    
    (map-set election-districts { election-id: election-id, district-id: district-id }
      {
        district-name: district-name,
        population: population,
        registered-voters: u0,
        polling-locations: polling-locations,
        district-official: district-official
      }
    )
    
    (record-registry-event "REGISTER_DISTRICT" election-id tx-sender "MEDIUM")
    (ok true)
  )
)

;; Election certification
(define-public (certify-election
  (election-id uint)
  (certification-status (string-ascii 30))
  (audit-results (string-ascii 300))
  (public-hash (buff 32))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (election-data (unwrap! (map-get? election-registry election-id) ERR-NOT-FOUND))
      (stats-data (unwrap! (map-get? election-statistics election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (or (is-eq (get status election-data) "ENDED")
                    (is-eq (get status election-data) "FINALIZED"))
                ERR-INVALID-STATE)
      
      (map-set certification-records election-id
        {
          election-id: election-id,
          certifier: tx-sender,
          certification-date: current-time,
          certification-status: certification-status,
          audit-results: audit-results,
          public-hash: public-hash
        }
      )
      
      (map-set election-statistics election-id
        (merge stats-data { certification-status: certification-status })
      )
      
      (record-registry-event "CERTIFY_ELECTION" election-id tx-sender "HIGH")
      (ok true)
    )
  )
)

;; Statistics and reporting
(define-public (update-election-statistics
  (election-id uint)
  (total-candidates uint)
  (total-votes-cast uint)
  (results-published bool)
)
  (let
    (
      (stats-data (unwrap! (map-get? election-statistics election-id) ERR-NOT-FOUND))
      (participation-rate (if (> (get total-registered-voters stats-data) u0)
                             (/ (* total-votes-cast u100) (get total-registered-voters stats-data))
                             u0))
    )
    (begin
      (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
      
      (map-set election-statistics election-id
        (merge stats-data {
          total-candidates: total-candidates,
          total-votes-cast: total-votes-cast,
          participation-rate: participation-rate,
          results-published: results-published
        })
      )
      
      (record-registry-event "UPDATE_STATISTICS" election-id tx-sender "LOW")
      (ok true)
    )
  )
)

;; Read-only functions
(define-read-only (get-election-registry-info (election-id uint))
  (map-get? election-registry election-id)
)

(define-read-only (get-election-statistics (election-id uint))
  (map-get? election-statistics election-id)
)

(define-read-only (get-voter-registration-status
  (election-id uint)
  (voter principal)
)
  (map-get? voter-registration-requests { election-id: election-id, voter: voter })
)

(define-read-only (get-election-official
  (election-id uint)
  (official principal)
)
  (map-get? election-officials { election-id: election-id, official: official })
)

(define-read-only (get-district-info
  (election-id uint)
  (district-id (string-ascii 50))
)
  (map-get? election-districts { election-id: election-id, district-id: district-id })
)

(define-read-only (get-certification-record (election-id uint))
  (map-get? certification-records election-id)
)

(define-read-only (is-registry-administrator (user principal))
  (default-to false (map-get? registry-administrators user))
)

(define-read-only (get-registry-event (event-id uint))
  (map-get? registry-events event-id)
)

(define-read-only (get-total-elections)
  (var-get total-elections)
)

(define-read-only (get-total-registered-voters)
  (var-get total-registered-voters)
)

(define-read-only (get-registry-status)
  (var-get registry-status)
)

(define-read-only (is-voter-eligible
  (election-id uint)
  (voter principal)
)
  (match (map-get? voter-registration-requests { election-id: election-id, voter: voter })
    registration-data (is-eq (get approval-status registration-data) "APPROVED")
    false
  )
)

(define-read-only (get-election-participation-rate (election-id uint))
  (match (map-get? election-statistics election-id)
    stats-data (get participation-rate stats-data)
    u0
  )
)

;; Private helper functions
(define-private (record-registry-event
  (event-type (string-ascii 50))
  (election-id uint)
  (actor principal)
  (impact-level (string-ascii 20))
)
  (let
    (
      (event-id (var-get next-event-id))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (map-set registry-events event-id
        {
          event-type: event-type,
          election-id: election-id,
          actor: actor,
          timestamp: current-time,
          details: "",
          impact-level: impact-level
        }
      )
      (var-set next-event-id (+ event-id u1))
      event-id
    )
  )
)

;; Batch operations
(define-public (batch-approve-voters
  (approvals (list 20 { election-id: uint, voter: principal, approved: bool }))
)
  (begin
    (asserts! (default-to false (map-get? registry-administrators tx-sender)) ERR-UNAUTHORIZED)
    (ok (map process-voter-approval approvals))
  )
)

(define-private (process-voter-approval
  (approval-info { election-id: uint, voter: principal, approved: bool })
)
  (let
    (
      (election-id (get election-id approval-info))
      (voter (get voter approval-info))
      (approved (get approved approval-info))
    )
    (match (map-get? voter-registration-requests { election-id: election-id, voter: voter })
      registration-data
        (if (is-eq (get approval-status registration-data) "PENDING")
          (begin
            (map-set voter-registration-requests { election-id: election-id, voter: voter }
              (merge registration-data { 
                approval-status: (if approved "APPROVED" "REJECTED"),
                approver: (some tx-sender)
              })
            )
            true
          )
          false
        )
      false
    )
  )
)

;; Emergency and maintenance functions
(define-public (set-registry-status (new-status (string-ascii 20)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set registry-status new-status)
    (record-registry-event "SET_REGISTRY_STATUS" u0 tx-sender "HIGH")
    (ok true)
  )
)

(define-public (emergency-suspend-election (election-id uint))
  (let
    (
      (election-data (unwrap! (map-get? election-registry election-id) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
      
      (map-set election-registry election-id
        (merge election-data { status: "SUSPENDED" })
      )
      
      (record-registry-event "EMERGENCY_SUSPEND" election-id tx-sender "CRITICAL")
      (ok true)
    )
  )
)
