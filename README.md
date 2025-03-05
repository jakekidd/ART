# **ART: Autonomous Repository Token**

### **What is ART?**

ART (Autonomous Repository Token) is an **on-chain, evolving digital artifact**. Each ART contract is a **singular instance** that represents a **modifiable, ownable, and history-aware asset**.

It is **not** an NFT (ERC-721) because:

- It doesn’t track a **balance** of unique tokens—it **is** the artifact.
- Each contract **is** the asset itself, rather than a container for many assets.

It is **not** ERC-20 because:

- There’s no **fungibility**—ownership is singular.
- It’s not a ledger of balances, but a **stateful, evolving entity**.

### **How Does It Work?**

- ART contracts define a **2D grid of units**, each storing a **value, author, edit count, and historical link**.
- Ownership of the contract can be **transferred**, like a tokenized asset.
- Units can be **modified** based on configurable permissions (open, exclusive, or role-based).
- Contributions are **tracked** through a **cred system**, rewarding early contributions over later unit changes.
- Artifacts can be **frozen** permanently via edit limits or manual control.
- A **moderation system** allows the owner to **rewind** edits from malicious actors.

### **Why use ART?**

ART introduces a **new class of on-chain artifacts**:  
- **Modifiable yet immutable in history** (every change is stored).  
- **Ownable & transferable** (can be exchanged like digital collectibles).  
- **Collaborative & permissionable** (customizable editing rights).  
- **Self-contained** (does not rely on external registries).

### **What Can You Build?**

- **On-chain collaborative canvases** (e.g., pixel art, generative projects).
- **Evolving game assets** (territory control, dynamic maps).
- **Persistent knowledge bases** (editable but verifiable history).
