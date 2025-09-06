;; Citizen Identity Management Smart Contract
;; Manages digital identities, credentials, and verification for government services

;; Error constants
(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-EXISTS (err u409))
(define-constant ERR-INVALID-INPUT (err u400))
(define-constant ERR-EXPIRED (err u410))
(define-constant ERR-SUSPENDED (err u403))

;; Contract owner and administrator management
(define-constant CONTRACT-OWNER tx-sender)
(define-data-var admin-multisig-threshold uint u2)

;; Data structures
(define-map administrators principal bool)
(define-map citizens
  principal
  {
    citizen-id: (string-ascii 50),
    full-name: (string-ascii 100),
    date-of-birth: uint,
    registration-date: uint,
    status: (string-ascii 20),
    verification-level: uint
  }
)

(define-map credentials
  { citizen: principal, credential-type: (string-ascii 50) }
  {
    credential-id: (string-ascii 50),
    issuer: principal,
    issue-date: uint,
    expiration-date: uint,
    status: (string-ascii 20),
    metadata: (string-ascii 200)
  }
)

(define-map identity-verification
  principal
  {
    verification-method: (string-ascii 50),
    verifier: principal,
    verification-date: uint,
    biometric-hash: (buff 32),
    document-hashes: (list 5 (buff 32))
  }
)

(define-map administrative-actions
  uint
  {
    action-type: (string-ascii 50),
    target: principal,
    executor: principal,
    timestamp: uint,
    details: (string-ascii 200)
  }
)

;; Data variables
(define-data-var next-action-id uint u1)
(define-data-var total-citizens uint u0)
(define-data-var total-credentials uint u0)

;; Initialize contract owner as administrator
(map-set administrators CONTRACT-OWNER true)

;; Administrative functions
(define-public (add-administrator (new-admin principal))
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (default-to false (map-get? administrators tx-sender)))
              ERR-UNAUTHORIZED)
    (map-set administrators new-admin true)
    (record-admin-action "ADD_ADMIN" new-admin)
    (ok true)
  )
)

(define-public (remove-administrator (admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (not (is-eq admin CONTRACT-OWNER)) ERR-INVALID-INPUT)
    (map-delete administrators admin)
    (record-admin-action "REMOVE_ADMIN" admin)
    (ok true)
  )
)

;; Core identity management functions
(define-public (register-citizen 
  (citizen-id (string-ascii 50))
  (full-name (string-ascii 100))
  (date-of-birth uint)
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (asserts! (is-none (map-get? citizens tx-sender)) ERR-ALREADY-EXISTS)
      (asserts! (> (len citizen-id) u0) ERR-INVALID-INPUT)
      (asserts! (> (len full-name) u0) ERR-INVALID-INPUT)
      (asserts! (> date-of-birth u0) ERR-INVALID-INPUT)
      
      (map-set citizens tx-sender
        {
          citizen-id: citizen-id,
          full-name: full-name,
          date-of-birth: date-of-birth,
          registration-date: current-time,
          status: "PENDING",
          verification-level: u0
        }
      )
      
      (var-set total-citizens (+ (var-get total-citizens) u1))
      (ok true)
    )
  )
)

(define-public (verify-identity
  (citizen principal)
  (verification-method (string-ascii 50))
  (biometric-hash (buff 32))
  (document-hashes (list 5 (buff 32)))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (citizen-data (unwrap! (map-get? citizens citizen) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? administrators tx-sender)) ERR-UNAUTHORIZED)
      
      (map-set identity-verification citizen
        {
          verification-method: verification-method,
          verifier: tx-sender,
          verification-date: current-time,
          biometric-hash: biometric-hash,
          document-hashes: document-hashes
        }
      )
      
      (map-set citizens citizen
        (merge citizen-data { status: "VERIFIED", verification-level: u5 })
      )
      
      (record-admin-action "VERIFY_IDENTITY" citizen)
      (ok true)
    )
  )
)

(define-public (issue-credential
  (citizen principal)
  (credential-type (string-ascii 50))
  (credential-id (string-ascii 50))
  (expiration-date uint)
  (metadata (string-ascii 200))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (citizen-data (unwrap! (map-get? citizens citizen) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? administrators tx-sender)) ERR-UNAUTHORIZED)
      (asserts! (is-eq (get status citizen-data) "VERIFIED") ERR-UNAUTHORIZED)
      (asserts! (is-none (map-get? credentials { citizen: citizen, credential-type: credential-type })) 
                ERR-ALREADY-EXISTS)
      
      (map-set credentials { citizen: citizen, credential-type: credential-type }
        {
          credential-id: credential-id,
          issuer: tx-sender,
          issue-date: current-time,
          expiration-date: expiration-date,
          status: "ACTIVE",
          metadata: metadata
        }
      )
      
      (var-set total-credentials (+ (var-get total-credentials) u1))
      (record-admin-action "ISSUE_CREDENTIAL" citizen)
      (ok true)
    )
  )
)

(define-public (revoke-credential
  (citizen principal)
  (credential-type (string-ascii 50))
  (reason (string-ascii 200))
)
  (let
    (
      (credential-data (unwrap! (map-get? credentials { citizen: citizen, credential-type: credential-type }) 
                               ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? administrators tx-sender)) ERR-UNAUTHORIZED)
      
      (map-set credentials { citizen: citizen, credential-type: credential-type }
        (merge credential-data { status: "REVOKED" })
      )
      
      (record-admin-action "REVOKE_CREDENTIAL" citizen)
      (ok true)
    )
  )
)

(define-public (update-citizen-status
  (citizen principal)
  (new-status (string-ascii 20))
)
  (let
    (
      (citizen-data (unwrap! (map-get? citizens citizen) ERR-NOT-FOUND))
    )
    (begin
      (asserts! (default-to false (map-get? administrators tx-sender)) ERR-UNAUTHORIZED)
      
      (map-set citizens citizen
        (merge citizen-data { status: new-status })
      )
      
      (record-admin-action "UPDATE_STATUS" citizen)
      (ok true)
    )
  )
)

;; Read-only functions for verification and queries
(define-read-only (get-citizen-info (citizen principal))
  (map-get? citizens citizen)
)

(define-read-only (get-credential
  (citizen principal)
  (credential-type (string-ascii 50))
)
  (map-get? credentials { citizen: citizen, credential-type: credential-type })
)

(define-read-only (get-verification-info (citizen principal))
  (map-get? identity-verification citizen)
)

(define-read-only (is-verified (citizen principal))
  (match (map-get? citizens citizen)
    citizen-data (is-eq (get status citizen-data) "VERIFIED")
    false
  )
)

(define-read-only (has-valid-credential
  (citizen principal)
  (credential-type (string-ascii 50))
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (match (map-get? credentials { citizen: citizen, credential-type: credential-type })
      credential-data (and
        (is-eq (get status credential-data) "ACTIVE")
        (> (get expiration-date credential-data) current-time)
      )
      false
    )
  )
)

(define-read-only (is-administrator (user principal))
  (default-to false (map-get? administrators user))
)

(define-read-only (get-total-citizens)
  (var-get total-citizens)
)

(define-read-only (get-total-credentials)
  (var-get total-credentials)
)

(define-read-only (get-admin-action (action-id uint))
  (map-get? administrative-actions action-id)
)

;; Private helper functions
(define-private (record-admin-action
  (action-type (string-ascii 50))
  (target principal)
)
  (let
    (
      (action-id (var-get next-action-id))
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    )
    (begin
      (map-set administrative-actions action-id
        {
          action-type: action-type,
          target: target,
          executor: tx-sender,
          timestamp: current-time,
          details: ""
        }
      )
      (var-set next-action-id (+ action-id u1))
      action-id
    )
  )
)

;; Batch processing functions for efficiency
(define-public (batch-issue-credentials
  (citizens-credentials (list 10 { citizen: principal, credential-type: (string-ascii 50), credential-id: (string-ascii 50), expiration-date: uint, metadata: (string-ascii 200) }))
)
  (begin
    (asserts! (default-to false (map-get? administrators tx-sender)) ERR-UNAUTHORIZED)
    (ok (map process-credential-issuance citizens-credentials))
  )
)

(define-private (process-credential-issuance
  (credential-info { citizen: principal, credential-type: (string-ascii 50), credential-id: (string-ascii 50), expiration-date: uint, metadata: (string-ascii 200) })
)
  (let
    (
      (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
      (citizen (get citizen credential-info))
    )
    (match (map-get? citizens citizen)
      citizen-data
        (if (is-eq (get status citizen-data) "VERIFIED")
          (begin
            (map-set credentials 
              { citizen: citizen, credential-type: (get credential-type credential-info) }
              {
                credential-id: (get credential-id credential-info),
                issuer: tx-sender,
                issue-date: current-time,
                expiration-date: (get expiration-date credential-info),
                status: "ACTIVE",
                metadata: (get metadata credential-info)
              }
            )
            (var-set total-credentials (+ (var-get total-credentials) u1))
            true
          )
          false
        )
      false
    )
  )
)
