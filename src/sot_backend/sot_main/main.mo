import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Hash "mo:base/Hash";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Result "mo:base/Result";
import Option "mo:base/Option";
import Float "mo:base/Float";
import Buffer "mo:base/Buffer";

actor class SOTMain(ledgerCanister: Principal, escrowCanister: Principal) = self {
    
    // ============= TYPES =============
    
    public type User = {
        principal: Principal;
        username: Text;
        reputationScore: Float;
        totalJobsCompleted: Nat;
        totalJobsCreated: Nat;
        createdAt: Time.Time;
        isVerified: Bool;
    };

    public type JobStatus = {
        #Draft;
        #Open;
        #InProgress;
        #InDispute;
        #Completed;
        #Cancelled;
    };

    public type MilestoneStatus = {
        #Pending;
        #InProgress;
        #Submitted;
        #Approved;
        #Disputed;
        #Released;
    };

    public type Milestone = {
        id: Nat;
        description: Text;
        amount: Nat64; // satoshis
        status: MilestoneStatus;
        submittedAt: ?Time.Time;
        approvedAt: ?Time.Time;
        releasedAt: ?Time.Time;
    };

    public type Job = {
        id: Nat;
        client: Principal;
        freelancer: ?Principal;
        title: Text;
        description: Text;
        totalAmount: Nat64;
        platformFeePercentage: Nat64; // basis points
        status: JobStatus;
        milestones: [Milestone];
        createdAt: Time.Time;
        startedAt: ?Time.Time;
        completedAt: ?Time.Time;
        escrowTxid: ?Blob;
    };

    public type DisputeStatus = {
        #Open;
        #UnderReview;
        #Resolved;
        #Cancelled;
    };

    public type Dispute = {
        id: Nat;
        jobId: Nat;
        milestoneId: ?Nat;
        raisedBy: Principal;
        reason: Text;
        evidence: [Text];
        status: DisputeStatus;
        createdAt: Time.Time;
        resolvedAt: ?Time.Time;
        resolution: ?Text;
    };

    public type CreateJobRequest = {
        title: Text;
        description: Text;
        milestones: [MilestoneRequest];
    };

    public type MilestoneRequest = {
        description: Text;
        amount: Nat64;
    };

    // ============= STATE =============
    
    private stable var nextJobId: Nat = 0;
    private stable var nextDisputeId: Nat = 0;
    private stable var platformFeePercentage: Nat64 = 250; // 2.5%
    
    private stable var usersEntries: [(Principal, User)] = [];
    private stable var jobsEntries: [(Nat, Job)] = [];
    private stable var disputesEntries: [(Nat, Dispute)] = [];

    private var users = HashMap.HashMap<Principal, User>(10, Principal.equal, Principal.hash);
    private var jobs = HashMap.HashMap<Nat, Job>(10, Nat.equal, Hash.hash);
    private var disputes = HashMap.HashMap<Nat, Dispute>(10, Nat.equal, Hash.hash);

    // ============= UPGRADE HOOKS =============

    system func preupgrade() {
        usersEntries := Iter.toArray(users.entries());
        jobsEntries := Iter.toArray(jobs.entries());
        disputesEntries := Iter.toArray(disputes.entries());
    };

    system func postupgrade() {
        users := HashMap.fromIter<Principal, User>(usersEntries.vals(), 10, Principal.equal, Principal.hash);
        jobs := HashMap.fromIter<Nat, Job>(jobsEntries.vals(), 10, Nat.equal, Hash.hash);
        disputes := HashMap.fromIter<Nat, Dispute>(disputesEntries.vals(), 10, Nat.equal, Hash.hash);
        usersEntries := [];
        jobsEntries := [];
        disputesEntries := [];
    };

    // ============= USER MANAGEMENT =============

    public shared(msg) func registerUser(username: Text) : async Result.Result<User, Text> {
        let caller = msg.caller;
        
        if (Text.size(username) < 3 or Text.size(username) > 50) {
            return #err("Username must be between 3 and 50 characters");
        };

        switch (users.get(caller)) {
            case (?_user) { #err("User already registered") };
            case null {
                let user: User = {
                    principal = caller;
                    username = username;
                    reputationScore = 5.0;
                    totalJobsCompleted = 0;
                    totalJobsCreated = 0;
                    createdAt = Time.now();
                    isVerified = false;
                };
                users.put(caller, user);
                #ok(user)
            };
        };
    };

    public query func getUser(principal: Principal) : async ?User {
        users.get(principal)
    };

    public query(msg) func getMyProfile() : async ?User {
        users.get(msg.caller)
    };

    // ============= JOB MANAGEMENT =============

    public shared(msg) func createJob(request: CreateJobRequest) : async Result.Result<Job, Text> {
        let caller = msg.caller;

        switch (users.get(caller)) {
            case null { return #err("User not registered") };
            case (?_) {};
        };

        if (request.milestones.size() == 0) {
            return #err("Job must have at least one milestone");
        };

        let totalAmount = Array.foldLeft<MilestoneRequest, Nat64>(
            request.milestones,
            0,
            func(sum, m) { sum + m.amount }
        );

        let jobId = nextJobId;
        nextJobId += 1;

        let milestones = Array.tabulate<Milestone>(
            request.milestones.size(),
            func(i) {
                let m = request.milestones[i];
                {
                    id = i;
                    description = m.description;
                    amount = m.amount;
                    status = #Pending;
                    submittedAt = null;
                    approvedAt = null;
                    releasedAt = null;
                }
            }
        );

        let job: Job = {
            id = jobId;
            client = caller;
            freelancer = null;
            title = request.title;
            description = request.description;
            totalAmount = totalAmount;
            platformFeePercentage = platformFeePercentage;
            status = #Draft;
            milestones = milestones;
            createdAt = Time.now();
            startedAt = null;
            completedAt = null;
            escrowTxid = null;
        };

        jobs.put(jobId, job);

        // Update user stats
        switch (users.get(caller)) {
            case (?user) {
                let updatedUser = {
                    user with
                    totalJobsCreated = user.totalJobsCreated + 1;
                };
                users.put(caller, updatedUser);
            };
            case null {};
        };

        #ok(job)
    };

    public shared(msg) func assignFreelancer(jobId: Nat, freelancer: Principal) : async Result.Result<Job, Text> {
        let caller = msg.caller;

        switch (jobs.get(jobId)) {
            case null { #err("Job not found") };
            case (?job) {
                if (job.client != caller) {
                    return #err("Only client can assign freelancer");
                };

                if (job.status != #Draft and job.status != #Open) {
                    return #err("Job is not available for assignment");
                };

                switch (users.get(freelancer)) {
                    case null { return #err("Freelancer not registered") };
                    case (?_) {};
                };

                let updatedJob = {
                    job with
                    freelancer = ?freelancer;
                    status = #Open;
                };

                jobs.put(jobId, updatedJob);
                #ok(updatedJob)
            };
        };
    };

    public shared(msg) func startJob(jobId: Nat) : async Result.Result<Job, Text> {
        let caller = msg.caller;

        switch (jobs.get(jobId)) {
            case null { #err("Job not found") };
            case (?job) {
                if (job.client != caller) {
                    return #err("Only client can start job");
                };

                if (job.status != #Open) {
                    return #err("Job must be in Open status");
                };

                switch (job.freelancer) {
                    case null { return #err("No freelancer assigned") };
                    case (?_) {};
                };

                let milestones = Array.mapEntries<Milestone, Milestone>(
                    job.milestones,
                    func(i, m) {
                        if (i == 0) {
                            { m with status = #InProgress }
                        } else {
                            m
                        }
                    }
                );

                let updatedJob = {
                    job with
                    status = #InProgress;
                    startedAt = ?Time.now();
                    milestones = milestones;
                };

                jobs.put(jobId, updatedJob);
                #ok(updatedJob)
            };
        };
    };

    // ============= MILESTONE MANAGEMENT =============

    public shared(msg) func submitMilestone(jobId: Nat, milestoneId: Nat) : async Result.Result<Job, Text> {
        let caller = msg.caller;

        switch (jobs.get(jobId)) {
            case null { #err("Job not found") };
            case (?job) {
                switch (job.freelancer) {
                    case null { return #err("No freelancer assigned") };
                    case (?f) {
                        if (f != caller) {
                            return #err("Only assigned freelancer can submit milestone");
                        };
                    };
                };

                if (milestoneId >= job.milestones.size()) {
                    return #err("Milestone not found");
                };

                let milestone = job.milestones[milestoneId];
                if (milestone.status != #InProgress) {
                    return #err("Milestone is not in progress");
                };

                let milestones = Array.mapEntries<Milestone, Milestone>(
                    job.milestones,
                    func(i, m) {
                        if (i == milestoneId) {
                            {
                                m with
                                status = #Submitted;
                                submittedAt = ?Time.now();
                            }
                        } else {
                            m
                        }
                    }
                );

                let updatedJob = { job with milestones = milestones };
                jobs.put(jobId, updatedJob);
                #ok(updatedJob)
            };
        };
    };

    public shared(msg) func approveMilestone(jobId: Nat, milestoneId: Nat) : async Result.Result<Job, Text> {
        let caller = msg.caller;

        switch (jobs.get(jobId)) {
            case null { #err("Job not found") };
            case (?job) {
                if (job.client != caller) {
                    return #err("Only client can approve milestone");
                };

                if (milestoneId >= job.milestones.size()) {
                    return #err("Milestone not found");
                };

                let milestone = job.milestones[milestoneId];
                if (milestone.status != #Submitted) {
                    return #err("Milestone must be submitted first");
                };

                let milestones = Array.mapEntries<Milestone, Milestone>(
                    job.milestones,
                    func(i, m) {
                        if (i == milestoneId) {
                            {
                                m with
                                status = #Approved;
                                approvedAt = ?Time.now();
                            }
                        } else {
                            m
                        }
                    }
                );

                // Check if all milestones approved
                let allApproved = Array.foldLeft<Milestone, Bool>(
                    milestones,
                    true,
                    func(acc, m) { acc and (m.status == #Approved) }
                );

                var updatedJob = { job with milestones = milestones };

                if (allApproved) {
                    updatedJob := {
                        updatedJob with
                        status = #Completed;
                        completedAt = ?Time.now();
                    };

                    // Update reputation scores
                    switch (job.freelancer) {
                        case (?freelancerPrincipal) {
                            switch (users.get(freelancerPrincipal)) {
                                case (?freelancerUser) {
                                    let newRep = calculateReputation(freelancerUser.reputationScore, 5.0);
                                    let updatedFreelancer = {
                                        freelancerUser with
                                        totalJobsCompleted = freelancerUser.totalJobsCompleted + 1;
                                        reputationScore = newRep;
                                    };
                                    users.put(freelancerPrincipal, updatedFreelancer);
                                };
                                case null {};
                            };
                        };
                        case null {};
                    };

                    switch (users.get(job.client)) {
                        case (?clientUser) {
                            let newRep = calculateReputation(clientUser.reputationScore, 5.0);
                            let updatedClient = {
                                clientUser with
                                reputationScore = newRep;
                            };
                            users.put(job.client, updatedClient);
                        };
                        case null {};
                    };
                } else {
                    // Start next milestone
                    let milestonesWithNext = Array.mapEntries<Milestone, Milestone>(
                        milestones,
                        func(i, m) {
                            if (m.status == #Pending) {
                                // Find first pending and set to InProgress
                                let hasPreviousInProgress = Array.foldLeft<Milestone, Bool>(
                                    Array.tabulate<Milestone>(i, func(j) { milestones[j] }),
                                    false,
                                    func(acc, prev) { acc or (prev.status == #InProgress) }
                                );
                                if (not hasPreviousInProgress) {
                                    { m with status = #InProgress }
                                } else {
                                    m
                                }
                            } else {
                                m
                            }
                        }
                    );
                    updatedJob := { updatedJob with milestones = milestonesWithNext };
                };

                jobs.put(jobId, updatedJob);
                #ok(updatedJob)
            };
        };
    };

    // ============= DISPUTE MANAGEMENT =============

    public shared(msg) func raiseDispute(jobId: Nat, milestoneId: ?Nat, reason: Text) : async Result.Result<Dispute, Text> {
        let caller = msg.caller;

        switch (jobs.get(jobId)) {
            case null { #err("Job not found") };
            case (?job) {
                let isClient = job.client == caller;
                let isFreelancer = switch (job.freelancer) {
                    case (?f) { f == caller };
                    case null { false };
                };

                if (not isClient and not isFreelancer) {
                    return #err("Only client or freelancer can raise dispute");
                };

                if (Text.size(reason) < 10) {
                    return #err("Dispute reason must be at least 10 characters");
                };

                let disputeId = nextDisputeId;
                nextDisputeId += 1;

                let dispute: Dispute = {
                    id = disputeId;
                    jobId = jobId;
                    milestoneId = milestoneId;
                    raisedBy = caller;
                    reason = reason;
                    evidence = [];
                    status = #Open;
                    createdAt = Time.now();
                    resolvedAt = null;
                    resolution = null;
                };

                let updatedJob = { job with status = #InDispute };
                jobs.put(jobId, updatedJob);
                disputes.put(disputeId, dispute);

                #ok(dispute)
            };
        };
    };

    public query func getDispute(disputeId: Nat) : async ?Dispute {
        disputes.get(disputeId)
    };

    // ============= QUERY FUNCTIONS =============

    public query func getJob(jobId: Nat) : async ?Job {
        jobs.get(jobId)
    };

    public query(msg) func getMyJobs() : async [Job] {
        let caller = msg.caller;
        let jobsArray = Iter.toArray(jobs.vals());
        Array.filter<Job>(
            jobsArray,
            func(j) {
                j.client == caller or (switch (j.freelancer) {
                    case (?f) { f == caller };
                    case null { false };
                })
            }
        )
    };

    public query func getOpenJobs() : async [Job] {
        let jobsArray = Iter.toArray(jobs.vals());
        Array.filter<Job>(
            jobsArray,
            func(j) {
                j.status == #Open and Option.isNull(j.freelancer)
            }
        )
    };

    public query func getPlatformStats() : async (Nat, Nat, Nat) {
        let totalJobs = jobs.size();
        let jobsArray = Iter.toArray(jobs.vals());
        let completedJobs = Array.filter<Job>(
            jobsArray,
            func(j) { j.status == #Completed }
        ).size();
        let totalUsers = users.size();
        
        (totalJobs, completedJobs, totalUsers)
    };

    // ============= HELPER FUNCTIONS =============

    private func calculateReputation(current: Float, newScore: Float) : Float {
        let updated = (current * 0.8) + (newScore * 0.2);
        Float.min(10.0, Float.max(0.0, updated))
    };

    // ============= ADMIN FUNCTIONS =============

    public shared(msg) func setPlatformFee(newFee: Nat64) : async Result.Result<(), Text> {
        // In production, add proper admin check
        if (newFee > 1000) { // Max 10%
            return #err("Fee too high");
        };
        platformFeePercentage := newFee;
        #ok()
    };

    public query func getPlatformFee() : async Nat64 {
        platformFeePercentage
    };
}