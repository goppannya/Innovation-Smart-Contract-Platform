(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-UNAUTHORIZED (err u102))
(define-constant ERR-ALREADY-EXISTS (err u103))
(define-constant ERR-INVALID-AMOUNT (err u104))
(define-constant ERR-INSUFFICIENT-FUNDS (err u105))
(define-constant ERR-VOTING-CLOSED (err u106))
(define-constant ERR-ALREADY-VOTED (err u107))
(define-constant ERR-INVALID-STATUS (err u108))

(define-data-var next-project-id uint u0)
(define-data-var platform-fee-rate uint u250)
(define-data-var min-voting-period uint u1440)
(define-data-var voting-threshold uint u10)

(define-map projects
    { project-id: uint }
    {
        creator: principal,
        title: (string-ascii 100),
        description: (string-ascii 500),
        funding-goal: uint,
        current-funding: uint,
        voting-end-height: uint,
        votes-for: uint,
        votes-against: uint,
        status: (string-ascii 20),
        created-at: uint
    }
)

(define-map project-funders
    { project-id: uint, funder: principal }
    { amount: uint }
)

(define-map project-votes
    { project-id: uint, voter: principal }
    { vote: bool }
)

(define-map user-profiles
    { user: principal }
    {
        reputation: uint,
        projects-created: uint,
        projects-funded: uint,
        total-funded-amount: uint
    }
)

(define-map innovation-categories
    { category-id: uint }
    { name: (string-ascii 50), active: bool }
)

(define-map project-categories
    { project-id: uint }
    { category-id: uint }
)

(define-private (get-project-or-fail (project-id uint))
    (ok (unwrap! (map-get? projects { project-id: project-id }) ERR-NOT-FOUND))
)

(define-private (is-voting-active (project-id uint))
    (let ((project (unwrap! (map-get? projects { project-id: project-id }) false)))
        (< stacks-block-height (get voting-end-height project))
    )
)

(define-private (calculate-platform-fee (amount uint))
    (/ (* amount (var-get platform-fee-rate)) u10000)
)

(define-private (update-user-reputation (user principal) (points uint))
    (let ((profile (default-to
            { reputation: u0, projects-created: u0, projects-funded: u0, total-funded-amount: u0 }
            (map-get? user-profiles { user: user })
        )))
        (map-set user-profiles
            { user: user }
            (merge profile { reputation: (+ (get reputation profile) points) })
        )
    )
)

(define-private (increment-user-projects (user principal))
    (let ((profile (default-to
            { reputation: u0, projects-created: u0, projects-funded: u0, total-funded-amount: u0 }
            (map-get? user-profiles { user: user })
        )))
        (map-set user-profiles
            { user: user }
            (merge profile { projects-created: (+ (get projects-created profile) u1) })
        )
    )
)

(define-private (update-funder-stats (funder principal) (amount uint))
    (let ((profile (default-to
            { reputation: u0, projects-created: u0, projects-funded: u0, total-funded-amount: u0 }
            (map-get? user-profiles { user: funder })
        )))
        (map-set user-profiles
            { user: funder }
            (merge profile {
                projects-funded: (+ (get projects-funded profile) u1),
                total-funded-amount: (+ (get total-funded-amount profile) amount)
            })
        )
    )
)

(define-public (create-project (title (string-ascii 100)) (description (string-ascii 500)) (funding-goal uint) (category-id uint))
    (let ((project-id (var-get next-project-id)))
        (asserts! (> funding-goal u0) ERR-INVALID-AMOUNT)
        (var-set next-project-id (+ project-id u1))
        (map-set projects
            { project-id: project-id }
            {
                creator: tx-sender,
                title: title,
                description: description,
                funding-goal: funding-goal,
                current-funding: u0,
                voting-end-height: (+ stacks-block-height (var-get min-voting-period)),
                votes-for: u0,
                votes-against: u0,
                status: "active",
                created-at: stacks-block-height
            }
        )
        (map-set project-categories { project-id: project-id } { category-id: category-id })
        (increment-user-projects tx-sender)
        (update-user-reputation tx-sender u10)
        (ok project-id)
    )
)

(define-public (vote-on-project (project-id uint) (vote bool))
    (let ((project (try! (get-project-or-fail project-id))))
        (asserts! (is-voting-active project-id) ERR-VOTING-CLOSED)
        (asserts! (is-none (map-get? project-votes { project-id: project-id, voter: tx-sender })) ERR-ALREADY-VOTED)
        (map-set project-votes { project-id: project-id, voter: tx-sender } { vote: vote })
        (if vote
            (map-set projects
                { project-id: project-id }
                (merge project { votes-for: (+ (get votes-for project) u1) })
            )
            (map-set projects
                { project-id: project-id }
                (merge project { votes-against: (+ (get votes-against project) u1) })
            )
        )
        (update-user-reputation tx-sender u5)
        (ok true)
    )
)

(define-public (fund-project (project-id uint))
    (let (
        (project (try! (get-project-or-fail project-id)))
        (funding-amount (stx-get-balance tx-sender))
        (platform-fee (calculate-platform-fee funding-amount))
        (net-funding (- funding-amount platform-fee))
    )
        (asserts! (> funding-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (is-eq (get status project) "approved") ERR-INVALID-STATUS)
        (try! (stx-transfer? platform-fee tx-sender CONTRACT-OWNER))
        (try! (stx-transfer? net-funding tx-sender (get creator project)))
        (map-set project-funders
            { project-id: project-id, funder: tx-sender }
            { amount: funding-amount }
        )
        (map-set projects
            { project-id: project-id }
            (merge project { current-funding: (+ (get current-funding project) net-funding) })
        )
        (update-funder-stats tx-sender funding-amount)
        (update-user-reputation tx-sender u15)
        (update-user-reputation (get creator project) u20)
        (ok true)
    )
)

(define-public (finalize-voting (project-id uint))
    (let ((project (try! (get-project-or-fail project-id))))
        (asserts! (>= stacks-block-height (get voting-end-height project)) ERR-VOTING-CLOSED)
        (asserts! (is-eq (get status project) "active") ERR-INVALID-STATUS)
        (let ((total-votes (+ (get votes-for project) (get votes-against project)))
            (approval-rate (if (> total-votes u0)
                (/ (* (get votes-for project) u100) total-votes)
                u0
            )))
            (if (and (>= total-votes (var-get voting-threshold)) (>= approval-rate u60))
                (begin
                    (map-set projects
                        { project-id: project-id }
                        (merge project { status: "approved" })
                    )
                    (update-user-reputation (get creator project) u25)
                    (ok "approved")
                )
                (begin
                    (map-set projects
                        { project-id: project-id }
                        (merge project { status: "rejected" })
                    )
                    (ok "rejected")
                )
            )
        )
    )
)

(define-public (add-category (name (string-ascii 50)))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (let ((category-id (var-get next-project-id)))
            (map-set innovation-categories
                { category-id: category-id }
                { name: name, active: true }
            )
            (ok category-id)
        )
    )
)

(define-public (update-platform-settings (fee-rate uint) (min-voting uint) (threshold uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set platform-fee-rate fee-rate)
        (var-set min-voting-period min-voting)
        (var-set voting-threshold threshold)
        (ok true)
    )
)

(define-read-only (get-project (project-id uint))
    (map-get? projects { project-id: project-id })
)

(define-read-only (get-user-profile (user principal))
    (map-get? user-profiles { user: user })
)

(define-read-only (get-project-funding (project-id uint) (funder principal))
    (map-get? project-funders { project-id: project-id, funder: funder })
)

(define-read-only (get-user-vote (project-id uint) (voter principal))
    (map-get? project-votes { project-id: project-id, voter: voter })
)

(define-read-only (get-platform-stats)
    {
        total-projects: (var-get next-project-id),
        platform-fee-rate: (var-get platform-fee-rate),
        min-voting-period: (var-get min-voting-period),
        voting-threshold: (var-get voting-threshold)
    }
)

(define-read-only (get-category (category-id uint))
    (map-get? innovation-categories { category-id: category-id })
)

(define-read-only (get-project-category (project-id uint))
    (map-get? project-categories { project-id: project-id })
)