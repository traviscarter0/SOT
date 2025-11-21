# SOT - Freelancer Escrow Platform (Motoko) 
# Encode ChainFusion Hack
A decentralized freelancer escrow platform built on the Internet Computer using Motoko, with ckBTC for secure, trustless Bitcoin payments.

## 🌟 Features

### Core Functionality
- **ckBTC Escrow**: Secure deposits using wrapped Bitcoin on ICP
- **Milestone-based Payments**: Break projects into manageable milestones
- **Dispute Resolution**: Built-in arbitration system for conflicts
- **Reputation System**: Track and build credibility over time
- **Multi-canister Architecture**: Scalable, maintainable Motoko design

### Smart Features
- Platform fee (2.5% default, configurable)
- Automated fund releases on milestone approval
- Evidence submission for disputes
- Private messaging with arbitrators
- Transaction history and audit trail
- Stable memory for upgrades

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────┐
│                 Frontend (React)                 │
└───────────┬──────────────────────┬───────────────┘
            │                      │
            ▼                      ▼
┌─────────────────────┐  ┌──────────────────────┐
│   Main Canister     │  │  Dispute Canister    │
│  (Motoko)           │  │  (Motoko)            │
│  - User Management  │  │  - Arbitration       │
│  - Job Management   │  │  - Evidence          │
│  - Milestones       │  │  - Voting            │
└──────────┬──────────┘  └──────────────────────┘
           │
           ▼
┌─────────────────────┐  ┌──────────────────────┐
│  Escrow Canister    │◄─┤  ckBTC Ledger        │
│  (Motoko)           │  │  (ICRC-1)            │
│  - Fund Management  │  │                      │
│  - Transfers        │  │                      │
│  - Refunds          │  │                      │
└─────────────────────┘  └──────────────────────┘
```

## 📋 Prerequisites

- [DFX SDK](https://internetcomputer.org/docs/current/developer-docs/setup/install/) >= 0.16.0
- Node.js >= 18 (for frontend)
- Basic understanding of Motoko

## 🚀 Quick Start

### 1. Clone and Setup

```bash
# Clone the repository
git clone <your-repo>
cd sot-platform

# Start local replica
dfx start --clean --background
```

### 2. Create Canister Files

Create the following directory structure:

```
sot-platform/
├── src/
│   ├── sot_main/
│   │   └── main.mo
│   ├── sot_escrow/
│   │   └── main.mo
│   └── sot_dispute/
│       └── main.mo
├── dfx.json
├── deploy.sh
└── README.md
```

Copy the Motoko code into the respective `main.mo` files.

### 3. Deploy Canisters

```bash
# Make deploy script executable
chmod +x deploy.sh

# Deploy to local network
./deploy.sh local

# Or deploy to mainnet
./deploy.sh ic
```

### 4. Test the Platform

```bash
# Register as a user
dfx canister call sot_main registerUser '("alice")'

# Create a job with milestones
dfx canister call sot_main createJob '(
  record {
    title = "Website Development";
    description = "Build a modern website";
    milestones = vec {
      record {
        description = "Design mockups";
        amount = 50_000_000 : nat64;
      };
      record {
        description = "Frontend development";
        amount = 100_000_000 : nat64;
      };
      record {
        description = "Backend integration";
        amount = 150_000_000 : nat64;
      };
    }
  }
)'

# Check platform stats
dfx canister call sot_main getPlatformStats
```

## 📚 Canister API

### Main Canister

#### User Management
- `registerUser(username: Text) -> Result<User, Text>`
- `getUser(principal: Principal) -> ?User`
- `getMyProfile() -> ?User`

#### Job Management
- `createJob(request: CreateJobRequest) -> Result<Job, Text>`
- `assignFreelancer(jobId: Nat, freelancer: Principal) -> Result<Job, Text>`
- `startJob(jobId: Nat) -> Result<Job, Text>`
- `getJob(jobId: Nat) -> ?Job`
- `getMyJobs() -> [Job]`
- `getOpenJobs() -> [Job]`

#### Milestone Management
- `submitMilestone(jobId: Nat, milestoneId: Nat) -> Result<Job, Text>`
- `approveMilestone(jobId: Nat, milestoneId: Nat) -> Result<Job, Text>`

#### Disputes
- `raiseDispute(jobId: Nat, milestoneId: ?Nat, reason: Text) -> Result<Dispute, Text>`

### Escrow Canister

#### Escrow Operations
- `createEscrow(jobId: Nat, client: Principal, totalAmount: Nat64, platformFeePercentage: Nat64) -> Result<EscrowAccount, Text>`
- `depositToEscrow(jobId: Nat) -> Result<Nat, Text>`
- `releaseMilestoneFunds(jobId: Nat, milestoneId: Nat, amount: Nat64) -> Result<Nat, Text>`
- `refundEscrow(jobId: Nat) -> Result<Nat, Text>`

#### Queries
- `getEscrowBalance(jobId: Nat) -> ?Nat64`
- `getEscrowAccount(jobId: Nat) -> ?EscrowAccount`
- `getTransactions(jobId: Nat) -> [Transaction]`

### Dispute Canister

#### Dispute Management
- `createDispute(...) -> Result<Dispute, Text>`
- `submitEvidence(...) -> Result<Evidence, Text>`
- `sendDisputeMessage(...) -> Result<DisputeMessage, Text>`
- `assignArbitrator(disputeId: Nat, arbitrator: Principal) -> Result<(), Text>`
- `resolveDispute(...) -> Result<Dispute, Text>`

#### Queries
- `getDispute(disputeId: Nat) -> ?Dispute`
- `getMyDisputes() -> [Dispute]`
- `getOpenDisputes() -> [Dispute]`
- `isArbitrator(principal: Principal) -> Bool`

## 💰 ckBTC Integration

### Amounts in Satoshis
All amounts are stored and transferred in satoshis (1 ckBTC = 100,000,000 satoshis).

```motoko
// Examples in Motoko
let halfBtc: Nat64 = 50_000_000;      // 0.5 ckBTC
let oneBtc: Nat64 = 100_000_000;      // 1.0 ckBTC
let pointOneBtc: Nat64 = 10_000_000;  // 0.1 ckBTC
```

### Fee Structure
- **Platform Fee**: 2.5% (250 basis points) - configurable
- **ckBTC Transfer Fee**: 1000 e8s (10 satoshis) per transaction
- Fees are automatically calculated and distributed

### Payment Flow

1. **Job Creation**: Client creates job with milestones
2. **Escrow Creation**: Platform creates escrow account with unique subaccount
3. **Deposit**: Client deposits full amount to escrow
4. **Milestone Completion**: Freelancer completes and submits work
5. **Approval**: Client approves milestone
6. **Release**: Funds automatically released:
   - Freelancer receives: `milestone_amount - platform_fee`
   - Platform receives: `platform_fee`

## 🔐 Security Features

- **Principal-based Authentication**: IC native authentication
- **Escrow Protection**: Funds locked until approval or dispute resolution
- **Inter-canister Calls**: Only authorized canisters can trigger transfers
- **Dispute Mechanism**: Neutral arbitration for conflicts
- **Stable Storage**: Data persists across upgrades
- **Audit Trail**: All transactions recorded on-chain

## 📊 Reputation System

Users earn reputation through:
- Completed jobs
- Timely delivery
- Quality ratings
- Dispute outcomes

Formula (Motoko):
```motoko
private func calculateReputation(current: Float, newScore: Float) : Float {
    let updated = (current * 0.8) + (newScore * 0.2);
    Float.min(10.0, Float.max(0.0, updated))
};
```

## 🛠️ Development

### Project Structure

```
sot-platform/
├── src/
│   ├── sot_main/
│   │   └── main.mo           # Main canister
│   ├── sot_escrow/
│   │   └── main.mo           # Escrow canister
│   ├── sot_dispute/
│   │   └── main.mo           # Dispute canister
│   └── declarations/         # Generated declarations
├── dfx.json                  # DFX configuration
├── deploy.sh                 # Deployment script
├── test.sh                   # Test script
└── README.md
```

### Building

```bash
# Build all canisters
dfx build

# Build specific canister
dfx build sot_main

# Generate Candid interfaces
dfx generate
```

### Testing

```bash
# Run integration tests
chmod +x test.sh
./test.sh

# Or test manually
dfx canister call sot_main registerUser '("test_user")'
dfx canister call sot_main getPlatformStats
```

### Upgrading Canisters

```bash
# Upgrade with stable memory preservation
dfx canister install sot_main --mode upgrade

# Or use deploy (automatically chooses install/upgrade)
dfx deploy sot_main
```

## 🚢 Deployment Checklist

### Local Deployment
- [x] Start local replica
- [x] Deploy or configure ckBTC ledger
- [x] Deploy escrow canister
- [x] Deploy main canister
- [x] Deploy dispute canister
- [x] Configure inter-canister calls
- [x] Add initial arbitrators

### Mainnet Deployment
- [ ] Secure deployment identity with cycles
- [ ] Use mainnet ckBTC ledger: `mxzaz-hqaaa-aaaar-qaada-cai`
- [ ] Deploy with production configuration
- [ ] Verify canister controllers
- [ ] Set up monitoring and logging
- [ ] Add trusted arbitrators
- [ ] Test with small amounts first
- [ ] Configure frontend with canister IDs

## 💡 Usage Examples

### Complete Job Flow

```bash
# 1. Register users
dfx canister call sot_main registerUser '("client_alice")'
dfx canister call sot_main registerUser '("freelancer_bob")'

# 2. Get Bob's principal
BOB_PRINCIPAL=$(dfx identity get-principal)

# 3. Create job (as Alice)
dfx canister call sot_main createJob '(
  record {
    title = "Build Landing Page";
    description = "Modern landing page with animations";
    milestones = vec {
      record {
        description = "Design and mockups";
        amount = 50_000_000 : nat64;
      };
      record {
        description = "Implementation";
        amount = 100_000_000 : nat64;
      };
    }
  }
)'

# 4. Assign freelancer
dfx canister call sot_main assignFreelancer "(0, principal \"$BOB_PRINCIPAL\")"

# 5. Start job
dfx canister call sot_main startJob "(0)"

# 6. Freelancer submits milestone
dfx canister call sot_main submitMilestone "(0, 0)"

# 7. Client approves milestone
dfx canister call sot_main approveMilestone "(0, 0)"

# Funds automatically released!
```

## 🎯 Key Differences from Rust

### Motoko Advantages
- **Native to IC**: Designed specifically for the Internet Computer
- **Simpler Syntax**: More accessible for web developers
- **Automatic Memory Management**: No manual RefCell/borrow checking
- **Built-in Upgrade Hooks**: `preupgrade` and `postupgrade`
- **Actor Model**: Natural concurrent programming

### Important Notes
- Use `stable` variables for data that persists across upgrades
- HashMaps need manual serialization in upgrade hooks
- Motoko uses `Result.Result<Ok, Err>` for error handling
- Arrays are immutable; use buffers for dynamic data

## 🤝 Contributing

We welcome contributions! Areas for improvement:
- Advanced dispute resolution mechanisms
- Time-locked releases
- Multi-signature approvals
- Analytics dashboard
- Mobile app integration

## 📄 License

MIT License - see LICENSE file for details

## 🔗 Resources

- [Motoko Documentation](https://internetcomputer.org/docs/current/motoko/main/motoko)
- [Internet Computer](https://internetcomputer.org)
- [ckBTC Documentation](https://internetcomputer.org/docs/current/developer-docs/integrations/bitcoin/ckbtc)
- [ICRC-1 Standard](https://github.com/dfinity/ICRC-1)

## 📧 Support

For issues and questions:
- Open a GitHub issue
- Join the [DFINITY Developer Forum](https://forum.dfinity.org)
- Email: support@sot-platform.com

## 🎓 Learning Resources

New to Motoko? Check out:
- [Motoko Bootcamp](https://www.motokobootcamp.com/)
- [Internet Computer Developer Journey](https://internetcomputer.org/docs/current/tutorials/developer-journey/)
- [Motoko Playground](https://m7sm4-2iaaa-aaaab-qabra-cai.raw.ic0.app/)

---

Built with ❤️ on the Internet Computer using Motoko