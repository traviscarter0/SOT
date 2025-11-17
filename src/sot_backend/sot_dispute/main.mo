import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Hash "mo:base/Hash";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Result "mo:base/Result";
import Buffer "mo:base/Buffer";
import Option "mo:base/Option";

actor class SOTDispute(
    initialMainCanister: Principal,
    initialEscrowCanister: Principal,
    initialArbitrators: [Principal]
) = self {
    
    // ============= TYPES =============
    
    public type DisputeStatus = {
        #Open;
        #UnderReview;
        #AwaitingEvidence;
        #InMediation;
        #Resolved;
        #Cancelled;
    };

    public type DisputeResolution = {
        #ClientWins;
        #FreelancerWins;
        #PartialClientRefund: Nat64; // percentage as basis points
        #Split: (Nat64, Nat64); // client %, freelancer %
    };

    public type Dispute = {
        id: Nat;
        jobId: Nat;
        milestoneId: ?Nat;
        client: Principal;
        freelancer: Principal;
        raisedBy: Principal;
        reason: Text;
        status: DisputeStatus;
        createdAt: Time.Time;
        updatedAt: Time.Time;
        resolvedAt: ?Time.Time;
        resolution: ?DisputeResolution;
        resolutionNotes: ?Text;
        arbitrator: ?Principal;
    };

    public type EvidenceType = {
        #Text;
        #Link;
        #Document;
        #Screenshot;
    };

    public type Evidence = {
        id: Nat;
        disputeId: Nat;
        submittedBy: Principal;
        contentType: EvidenceType;
        description: Text;
        url: ?Text;
        submittedAt: Time.Time;
    };

    public type DisputeMessage = {
        id: Nat;
        disputeId: Nat;
        sender: Principal;
        message: Text;
        timestamp: Time.Time;
        isPrivate: Bool; // visible only to arbitrator
    };

    public type Vote = {
        arbitrator: Principal;
        disputeId: Nat;
        decision: DisputeResolution;
        reasoning: Text;
        timestamp: Time.Time;
    };

    // ============= STATE =============
    
    private stable var mainCanister: Principal = initialMainCanister;
    private stable var escrowCanister: Principal = initialEscrowCanister;
    private stable var nextDisputeId: Nat = 0;
    private stable var nextEvidenceId: Nat = 0;
    private stable var nextMessageId: Nat = 0;
    
    private stable var arbitratorsArray: [Principal] = initialArbitrators;
    private stable var disputesEntries: [(Nat, Dispute)] = [];
    private stable var evidenceEntries: [(Nat, Evidence)] = [];
    private stable var messagesEntries: [(Nat, [DisputeMessage])] = [];
    private stable var votesEntries: [(Nat, [Vote])] = [];

    private var disputes = HashMap.HashMap<Nat, Dispute>(10, Nat.equal, Hash.hash);
    private var evidenceMap = HashMap.HashMap<Nat, Evidence>(10, Nat.equal, Hash.hash);
    private var messages = HashMap.HashMap<Nat, [DisputeMessage]>(10, Nat.equal, Hash.hash);
    private var votes = HashMap.HashMap<Nat, [Vote]>(10, Nat.equal, Hash.hash);

    // ============= UPGRADE HOOKS =============

    system func preupgrade() {
        disputesEntries := Iter.toArray(disputes.entries());
        evidenceEntries := Iter.toArray(evidenceMap.entries());
        messagesEntries := Iter.toArray(messages.entries());
        votesEntries := Iter.toArray(votes.entries());
    };

    system func postupgrade() {
        disputes := HashMap.fromIter<Nat, Dispute>(disputesEntries.vals(), 10, Nat.equal, Hash.hash);
        evidenceMap := HashMap.fromIter<Nat, Evidence>(evidenceEntries.vals(), 10, Nat.equal, Hash.hash);
        messages := HashMap.fromIter<Nat, [DisputeMessage]>(messagesEntries.vals(), 10, Nat.equal, Hash.hash);
        votes := HashMap.fromIter<Nat, [Vote]>(votesEntries.vals(), 10, Nat.equal, Hash.hash);
        disputesEntries := [];
        evidenceEntries := [];
        messagesEntries := [];
        votesEntries := [];
    };

    // ============= DISPUTE CREATION =============

    public shared(msg) func createDispute(
        jobId: Nat,
        milestoneId: ?Nat,
        client: Principal,
        freelancer: Principal,
        reason: Text
    ) : async Result.Result<Dispute, Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can create disputes");
        };

        if (Text.size(reason) < 20) {
            return #err("Dispute reason must be at least 20 characters");
        };

        let disputeId = nextDisputeId;
        nextDisputeId += 1;

        let dispute: Dispute = {
            id = disputeId;
            jobId = jobId;
            milestoneId = milestoneId;
            client = client;
            freelancer = freelancer;
            raisedBy = msg.caller;
            reason = reason;
            status = #Open;
            createdAt = Time.now();
            updatedAt = Time.now();
            resolvedAt = null;
            resolution = null;
            resolutionNotes = null;
            arbitrator = null;
        };

        disputes.put(disputeId, dispute);
        messages.put(disputeId, []);
        votes.put(disputeId, []);

        #ok(dispute)
    };

    // ============= EVIDENCE SUBMISSION =============

    public shared(msg) func submitEvidence(
        disputeId: Nat,
        contentType: EvidenceType,
        description: Text,
        url: ?Text
    ) : async Result.Result<Evidence, Text> {
        let caller = msg.caller;

        switch (disputes.get(disputeId)) {
            case null { #err("Dispute not found") };
            case (?dispute) {
                if (dispute.client != caller and dispute.freelancer != caller) {
                    return #err("Only parties involved can submit evidence");
                };

                if (dispute.status == #Resolved or dispute.status == #Cancelled) {
                    return #err("Cannot submit evidence to closed dispute");
                };

                let evidenceId = nextEvidenceId;
                nextEvidenceId += 1;

                let evidence: Evidence = {
                    id = evidenceId;
                    disputeId = disputeId;
                    submittedBy = caller;
                    contentType = contentType;
                    description = description;
                    url = url;
                    submittedAt = Time.now();
                };

                evidenceMap.put(evidenceId, evidence);
                #ok(evidence)
            };
        };
    };

    // ============= MESSAGING =============

    public shared(msg) func sendDisputeMessage(
        disputeId: Nat,
        message: Text,
        isPrivate: Bool
    ) : async Result.Result<DisputeMessage, Text> {
        let caller = msg.caller;

        switch (disputes.get(disputeId)) {
            case null { #err("Dispute not found") };
            case (?dispute) {
                let isArbitrator = arrayContains(arbitratorsArray, caller);
                
                if (dispute.client != caller and dispute.freelancer != caller and not isArbitrator) {
                    return #err("Only parties involved or arbitrators can send messages");
                };

                if (isPrivate and not isArbitrator) {
                    switch (dispute.arbitrator) {
                        case (?arb) {
                            if (arb != caller) {
                                return #err("Only arbitrators can send private messages");
                            };
                        };
                        case null {
                            return #err("Only arbitrators can send private messages");
                        };
                    };
                };

                let messageId = nextMessageId;
                nextMessageId += 1;

                let disputeMessage: DisputeMessage = {
                    id = messageId;
                    disputeId = disputeId;
                    sender = caller;
                    message = message;
                    timestamp = Time.now();
                    isPrivate = isPrivate;
                };

                switch (messages.get(disputeId)) {
                    case null {
                        messages.put(disputeId, [disputeMessage]);
                    };
                    case (?existing) {
                        let updated = Array.append<DisputeMessage>(existing, [disputeMessage]);
                        messages.put(disputeId, updated);
                    };
                };

                #ok(disputeMessage)
            };
        };
    };

    // ============= ARBITRATION =============

    public shared(msg) func assignArbitrator(disputeId: Nat, arbitrator: Principal) : async Result.Result<(), Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can assign arbitrators");
        };

        if (not arrayContains(arbitratorsArray, arbitrator)) {
            return #err("Invalid arbitrator");
        };

        switch (disputes.get(disputeId)) {
            case null { #err("Dispute not found") };
            case (?dispute) {
                if (dispute.status != #Open and dispute.status != #AwaitingEvidence) {
                    return #err("Dispute is not in assignable state");
                };

                let updated = {
                    dispute with
                    arbitrator = ?arbitrator;
                    status = #UnderReview;
                    updatedAt = Time.now();
                };

                disputes.put(disputeId, updated);
                #ok()
            };
        };
    };

    public shared(msg) func resolveDispute(
        disputeId: Nat,
        resolution: DisputeResolution,
        resolutionNotes: Text
    ) : async Result.Result<Dispute, Text> {
        let caller = msg.caller;

        switch (disputes.get(disputeId)) {
            case null { #err("Dispute not found") };
            case (?dispute) {
                let isValidArbitrator = switch (dispute.arbitrator) {
                    case (?arb) { arb == caller };
                    case null { false };
                };

                let isArbitrator = arrayContains(arbitratorsArray, caller);

                if (not isValidArbitrator and not isArbitrator) {
                    return #err("Only assigned arbitrator can resolve dispute");
                };

                if (dispute.status == #Resolved or dispute.status == #Cancelled) {
                    return #err("Dispute already closed");
                };

                let updated = {
                    dispute with
                    status = #Resolved;
                    resolution = ?resolution;
                    resolutionNotes = ?resolutionNotes;
                    resolvedAt = ?Time.now();
                    updatedAt = Time.now();
                };

                disputes.put(disputeId, updated);

                // Record arbitrator vote
                let vote: Vote = {
                    arbitrator = caller;
                    disputeId = disputeId;
                    decision = resolution;
                    reasoning = resolutionNotes;
                    timestamp = Time.now();
                };

                switch (votes.get(disputeId)) {
                    case null {
                        votes.put(disputeId, [vote]);
                    };
                    case (?existing) {
                        let updatedVotes = Array.append<Vote>(existing, [vote]);
                        votes.put(disputeId, updatedVotes);
                    };
                };

                #ok(updated)
            };
        };
    };

    // ============= ARBITRATOR MANAGEMENT =============

    public shared(msg) func addArbitrator(arbitrator: Principal) : async Result.Result<(), Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can add arbitrators");
        };

        if (arrayContains(arbitratorsArray, arbitrator)) {
            return #err("Already an arbitrator");
        };

        arbitratorsArray := Array.append<Principal>(arbitratorsArray, [arbitrator]);
        #ok()
    };

    public shared(msg) func removeArbitrator(arbitrator: Principal) : async Result.Result<(), Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can remove arbitrators");
        };

        arbitratorsArray := Array.filter<Principal>(
            arbitratorsArray,
            func(a) { a != arbitrator }
        );
        #ok()
    };

    // ============= QUERY FUNCTIONS =============

    public query func getDispute(disputeId: Nat) : async ?Dispute {
        disputes.get(disputeId)
    };

    public query func getDisputeEvidence(disputeId: Nat) : async [Evidence] {
        let evidenceArray = Iter.toArray(evidenceMap.vals());
        Array.filter<Evidence>(
            evidenceArray,
            func(e) { e.disputeId == disputeId }
        )
    };

    public query(msg) func getDisputeMessages(disputeId: Nat) : async [DisputeMessage] {
        let caller = msg.caller;
        let isArbitrator = arrayContains(arbitratorsArray, caller);
        
        switch (disputes.get(disputeId)) {
            case null { [] };
            case (?dispute) {
                let isParty = dispute.client == caller or dispute.freelancer == caller;

                switch (messages.get(disputeId)) {
                    case null { [] };
                    case (?msgs) {
                        Array.filter<DisputeMessage>(
                            msgs,
                            func(m) {
                                not m.isPrivate or isArbitrator
                            }
                        )
                    };
                };
            };
        };
    };

    public query func getOpenDisputes() : async [Dispute] {
        let disputesArray = Iter.toArray(disputes.vals());
        Array.filter<Dispute>(
            disputesArray,
            func(d) {
                d.status == #Open or d.status == #AwaitingEvidence
            }
        )
    };

    public query(msg) func getMyDisputes() : async [Dispute] {
        let caller = msg.caller;
        let disputesArray = Iter.toArray(disputes.vals());
        Array.filter<Dispute>(
            disputesArray,
            func(d) {
                d.client == caller or d.freelancer == caller
            }
        )
    };

    public query(msg) func getArbitratorDisputes() : async [Dispute] {
        let caller = msg.caller;
        
        if (not arrayContains(arbitratorsArray, caller)) {
            return [];
        };

        let disputesArray = Iter.toArray(disputes.vals());
        Array.filter<Dispute>(
            disputesArray,
            func(d) {
                switch (d.arbitrator) {
                    case (?arb) { arb == caller };
                    case null { d.status == #Open };
                }
            }
        )
    };

    public query func isArbitrator(principal: Principal) : async Bool {
        arrayContains(arbitratorsArray, principal)
    };

    public query func getArbitrators() : async [Principal] {
        arbitratorsArray
    };

    public query func getDisputeStats() : async (Nat, Nat, Nat) {
        let total = disputes.size();
        let disputesArray = Iter.toArray(disputes.vals());
        
        let resolved = Array.filter<Dispute>(
            disputesArray,
            func(d) { d.status == #Resolved }
        ).size();
        
        let open = Array.filter<Dispute>(
            disputesArray,
            func(d) {
                d.status == #Open or d.status == #UnderReview
            }
        ).size();
        
        (total, resolved, open)
    };

    // ============= HELPER FUNCTIONS =============

    private func arrayContains(arr: [Principal], item: Principal) : Bool {
        Array.foldLeft<Principal, Bool>(
            arr,
            false,
            func(acc, p) { acc or Principal.equal(p, item) }
        )
    };
}