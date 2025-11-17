import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Hash "mo:base/Hash";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import Option "mo:base/Option";

actor class SOTEscrow(
    initialLedgerCanister: Principal,
    initialMainCanister: Principal,
    initialPlatformWallet: Principal
) = self {
    
    // ============= TYPES =============
    
    public type EscrowAccount = {
        jobId: Nat;
        client: Principal;
        freelancer: ?Principal;
        totalAmount: Nat64;
        platformFee: Nat64;
        releasedAmount: Nat64;
        createdAt: Time.Time;
        subaccount: [Nat8];
    };

    public type TransactionType = {
        #Deposit;
        #MilestoneRelease;
        #PlatformFee;
        #Refund;
    };

    public type Transaction = {
        id: Nat;
        jobId: Nat;
        milestoneId: ?Nat;
        from: Principal;
        to: Principal;
        amount: Nat64;
        txType: TransactionType;
        blockHeight: ?Nat64;
        timestamp: Time.Time;
    };

    // ICRC-1 Transfer types
    public type Account = {
        owner: Principal;
        subaccount: ?[Nat8];
    };

    public type TransferArg = {
        from_subaccount: ?[Nat8];
        to: Account;
        amount: Nat;
        fee: ?Nat;
        memo: ?Blob;
        created_at_time: ?Nat64;
    };

    public type TransferError = {
        #BadFee: { expected_fee: Nat };
        #BadBurn: { min_burn_amount: Nat };
        #InsufficientFunds: { balance: Nat };
        #TooOld;
        #CreatedInFuture: { ledger_time: Nat64 };
        #Duplicate: { duplicate_of: Nat };
        #TemporarilyUnavailable;
        #GenericError: { error_code: Nat; message: Text };
    };

    // ============= STATE =============
    
    private stable var ledgerCanister: Principal = initialLedgerCanister;
    private stable var mainCanister: Principal = initialMainCanister;
    private stable var platformWallet: Principal = initialPlatformWallet;
    private stable var nextTransactionId: Nat = 0;
    
    private stable var escrowAccountsEntries: [(Nat, EscrowAccount)] = [];
    private stable var transactionsEntries: [(Nat, Transaction)] = [];

    private var escrowAccounts = HashMap.HashMap<Nat, EscrowAccount>(10, Nat.equal, Hash.hash);
    private var transactions = HashMap.HashMap<Nat, Transaction>(10, Nat.equal, Hash.hash);

    // ============= UPGRADE HOOKS =============

    system func preupgrade() {
        escrowAccountsEntries := Iter.toArray(escrowAccounts.entries());
        transactionsEntries := Iter.toArray(transactions.entries());
    };

    system func postupgrade() {
        escrowAccounts := HashMap.fromIter<Nat, EscrowAccount>(escrowAccountsEntries.vals(), 10, Nat.equal, Hash.hash);
        transactions := HashMap.fromIter<Nat, Transaction>(transactionsEntries.vals(), 10, Nat.equal, Hash.hash);
        escrowAccountsEntries := [];
        transactionsEntries := [];
    };

    // ============= LEDGER INTERFACE =============

    let Ledger = actor(Principal.toText(ledgerCanister)) : actor {
        icrc1_transfer: (TransferArg) -> async Result.Result<Nat, TransferError>;
    };

    // ============= ESCROW MANAGEMENT =============

    public shared(msg) func createEscrow(
        jobId: Nat,
        client: Principal,
        totalAmount: Nat64,
        platformFeePercentage: Nat64
    ) : async Result.Result<EscrowAccount, Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can create escrow");
        };

        let platformFee = (totalAmount * platformFeePercentage) / 10000;
        let subaccount = generateSubaccount(jobId);

        let escrow: EscrowAccount = {
            jobId = jobId;
            client = client;
            freelancer = null;
            totalAmount = totalAmount;
            platformFee = platformFee;
            releasedAmount = 0;
            createdAt = Time.now();
            subaccount = subaccount;
        };

        escrowAccounts.put(jobId, escrow);
        #ok(escrow)
    };

    public shared(msg) func setFreelancer(jobId: Nat, freelancer: Principal) : async Result.Result<(), Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can set freelancer");
        };

        switch (escrowAccounts.get(jobId)) {
            case null { #err("Escrow account not found") };
            case (?escrow) {
                let updated = {
                    escrow with
                    freelancer = ?freelancer;
                };
                escrowAccounts.put(jobId, updated);
                #ok()
            };
        };
    };

    // ============= DEPOSIT HANDLING =============

    public shared(msg) func depositToEscrow(jobId: Nat) : async Result.Result<Nat, Text> {
        let caller = msg.caller;

        switch (escrowAccounts.get(jobId)) {
            case null { #err("Escrow account not found") };
            case (?escrow) {
                if (escrow.client != caller) {
                    return #err("Only client can deposit to escrow");
                };

                // Transfer from client to this canister's subaccount
                let escrowAccount: Account = {
                    owner = Principal.fromActor(self);
                    subaccount = ?escrow.subaccount;
                };

                let transferArgs: TransferArg = {
                    from_subaccount = null;
                    to = escrowAccount;
                    amount = Nat64.toNat(escrow.totalAmount);
                    fee = ?1000; // ckBTC fee (10 satoshis = 1000 e8s)
                    memo = ?Blob.fromArray([]);
                    created_at_time = null;
                };

                try {
                    let blockHeight = await Ledger.icrc1_transfer(transferArgs);
                    switch (blockHeight) {
                        case (#ok(height)) {
                            // Record transaction
                            let txId = nextTransactionId;
                            nextTransactionId += 1;

                            let transaction: Transaction = {
                                id = txId;
                                jobId = jobId;
                                milestoneId = null;
                                from = caller;
                                to = Principal.fromActor(self);
                                amount = escrow.totalAmount;
                                txType = #Deposit;
                                blockHeight = ?Nat64.fromNat(height);
                                timestamp = Time.now();
                            };

                            transactions.put(txId, transaction);
                            #ok(txId)
                        };
                        case (#err(error)) {
                            #err("Transfer failed: " # debug_show(error))
                        };
                    };
                } catch (e) {
                    #err("Deposit failed: " # Error.message(e))
                };
            };
        };
    };

    // ============= RELEASE FUNDS =============

    public shared(msg) func releaseMilestoneFunds(
        jobId: Nat,
        milestoneId: Nat,
        amount: Nat64
    ) : async Result.Result<Nat, Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can release funds");
        };

        switch (escrowAccounts.get(jobId)) {
            case null { #err("Escrow account not found") };
            case (?escrow) {
                switch (escrow.freelancer) {
                    case null { return #err("No freelancer assigned") };
                    case (?freelancer) {
                        if (escrow.releasedAmount + amount > escrow.totalAmount) {
                            return #err("Insufficient escrow balance");
                        };

                        // Calculate platform fee for this milestone
                        let platformFeeAmount = (amount * escrow.platformFee) / escrow.totalAmount;
                        let freelancerAmount = amount - platformFeeAmount;

                        // Transfer to freelancer
                        let freelancerAccount: Account = {
                            owner = freelancer;
                            subaccount = null;
                        };

                        let transferArgs: TransferArg = {
                            from_subaccount = ?escrow.subaccount;
                            to = freelancerAccount;
                            amount = Nat64.toNat(freelancerAmount);
                            fee = ?1000;
                            memo = ?Blob.fromArray([]);
                            created_at_time = null;
                        };

                        try {
                            let blockHeight = await Ledger.icrc1_transfer(transferArgs);
                            switch (blockHeight) {
                                case (#ok(height)) {
                                    // Record freelancer transaction
                                    let txId = nextTransactionId;
                                    nextTransactionId += 1;

                                    let transaction: Transaction = {
                                        id = txId;
                                        jobId = jobId;
                                        milestoneId = ?milestoneId;
                                        from = Principal.fromActor(self);
                                        to = freelancer;
                                        amount = freelancerAmount;
                                        txType = #MilestoneRelease;
                                        blockHeight = ?Nat64.fromNat(height);
                                        timestamp = Time.now();
                                    };

                                    transactions.put(txId, transaction);

                                    // Transfer platform fee if amount > 0
                                    if (platformFeeAmount > 0) {
                                        let platformAccount: Account = {
                                            owner = platformWallet;
                                            subaccount = null;
                                        };

                                        let feeTransferArgs: TransferArg = {
                                            from_subaccount = ?escrow.subaccount;
                                            to = platformAccount;
                                            amount = Nat64.toNat(platformFeeAmount);
                                            fee = ?1000;
                                            memo = ?Blob.fromArray([]);
                                            created_at_time = null;
                                        };

                                        let feeBlockHeight = await Ledger.icrc1_transfer(feeTransferArgs);
                                        switch (feeBlockHeight) {
                                            case (#ok(feeHeight)) {
                                                let feeTxId = nextTransactionId;
                                                nextTransactionId += 1;

                                                let feeTransaction: Transaction = {
                                                    id = feeTxId;
                                                    jobId = jobId;
                                                    milestoneId = ?milestoneId;
                                                    from = Principal.fromActor(self);
                                                    to = platformWallet;
                                                    amount = platformFeeAmount;
                                                    txType = #PlatformFee;
                                                    blockHeight = ?Nat64.fromNat(feeHeight);
                                                    timestamp = Time.now();
                                                };

                                                transactions.put(feeTxId, feeTransaction);
                                            };
                                            case (#err(_)) {
                                                // Platform fee transfer failed, but milestone was paid
                                            };
                                        };
                                    };

                                    // Update escrow account
                                    let updatedEscrow = {
                                        escrow with
                                        releasedAmount = escrow.releasedAmount + amount;
                                    };
                                    escrowAccounts.put(jobId, updatedEscrow);

                                    #ok(txId)
                                };
                                case (#err(error)) {
                                    #err("Transfer failed: " # debug_show(error))
                                };
                            };
                        } catch (e) {
                            #err("Release failed: " # Error.message(e))
                        };
                    };
                };
            };
        };
    };

    // ============= REFUND HANDLING =============

    public shared(msg) func refundEscrow(jobId: Nat) : async Result.Result<Nat, Text> {
        if (msg.caller != mainCanister) {
            return #err("Only main canister can process refunds");
        };

        switch (escrowAccounts.get(jobId)) {
            case null { #err("Escrow account not found") };
            case (?escrow) {
                let refundAmount = escrow.totalAmount - escrow.releasedAmount;
                
                if (refundAmount == 0) {
                    return #err("No funds to refund");
                };

                let clientAccount: Account = {
                    owner = escrow.client;
                    subaccount = null;
                };

                let transferArgs: TransferArg = {
                    from_subaccount = ?escrow.subaccount;
                    to = clientAccount;
                    amount = Nat64.toNat(refundAmount);
                    fee = ?1000;
                    memo = ?Blob.fromArray([]);
                    created_at_time = null;
                };

                try {
                    let blockHeight = await Ledger.icrc1_transfer(transferArgs);
                    switch (blockHeight) {
                        case (#ok(height)) {
                            let txId = nextTransactionId;
                            nextTransactionId += 1;

                            let transaction: Transaction = {
                                id = txId;
                                jobId = jobId;
                                milestoneId = null;
                                from = Principal.fromActor(self);
                                to = escrow.client;
                                amount = refundAmount;
                                txType = #Refund;
                                blockHeight = ?Nat64.fromNat(height);
                                timestamp = Time.now();
                            };

                            transactions.put(txId, transaction);

                            // Update escrow account
                            let updatedEscrow = {
                                escrow with
                                releasedAmount = escrow.totalAmount;
                            };
                            escrowAccounts.put(jobId, updatedEscrow);

                            #ok(txId)
                        };
                        case (#err(error)) {
                            #err("Refund transfer failed: " # debug_show(error))
                        };
                    };
                } catch (e) {
                    #err("Refund failed: " # Error.message(e))
                };
            };
        };
    };

    // ============= QUERY FUNCTIONS =============

    public query func getEscrowBalance(jobId: Nat) : async ?Nat64 {
        switch (escrowAccounts.get(jobId)) {
            case null { null };
            case (?escrow) {
                ?(escrow.totalAmount - escrow.releasedAmount)
            };
        };
    };

    public query func getEscrowAccount(jobId: Nat) : async ?EscrowAccount {
        escrowAccounts.get(jobId)
    };

    public query func getTransactions(jobId: Nat) : async [Transaction] {
        let txArray = Iter.toArray(transactions.vals());
        Array.filter<Transaction>(
            txArray,
            func(t) { t.jobId == jobId }
        )
    };

    public query func getEscrowSubaccount(jobId: Nat) : async ?[Nat8] {
        switch (escrowAccounts.get(jobId)) {
            case null { null };
            case (?escrow) { ?escrow.subaccount };
        };
    };

    // ============= HELPER FUNCTIONS =============

    private func generateSubaccount(jobId: Nat) : [Nat8] {
        let jobIdBytes = Nat64.toNat(Nat64.fromNat(jobId));
        Array.tabulate<Nat8>(
            32,
            func(i) {
                if (i >= 24) {
                    let shiftAmount = (31 - i) * 8;
                    Nat8.fromNat((jobIdBytes / (2 ** shiftAmount)) % 256)
                } else {
                    0
                }
            }
        )
    };

    // ============= ADMIN FUNCTIONS =============

    public shared(msg) func updateLedgerCanister(newLedger: Principal) : async () {
        // In production, add proper admin check
        ledgerCanister := newLedger;
    };

    public shared(msg) func updatePlatformWallet(newWallet: Principal) : async () {
        // In production, add proper admin check
        platformWallet := newWallet;
    };
}