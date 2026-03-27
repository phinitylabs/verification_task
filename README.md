# TPU Tile Orchestrator - RTL Implementation Task

## Task Selection Rationale

### Why This Task Was Chosen

This task focuses on implementing a **Tile Orchestrator** for a TPU (Tensor Processing Unit) architecture - a critical component in modern AI accelerator design. The orchestrator coordinates tile-based neural network processing through DMA transfers and MAC (Multiply-Accumulate) unit dispatch.

In the world of AI, the computational demands of Large Language Models (LLMs) have exploded exponentially. For example, running inference on a Llama 70B parameter model with 1 million token context requires an astronomical number of matrix multiplications. If a general-purpose CPU were to perform these calculations, it would be severely bottlenecked due to:
- Limited memory bandwidth
- Sequential execution constraints
- Thermal limitations under sustained compute loads

This is precisely why specialized hardware accelerators like TPUs, GPUs, and custom ASICs have become essential infrastructure for AI workloads.

### Industry Relevance

1. **AI Accelerator Market Growth**: The AI chip market is projected to exceed $100B by 2027, driven by demand for efficient LLM inference and training hardware.

2. **Double Buffering Architecture**: The technique implemented here - double buffering with tile-based data movement - is fundamental to achieving high throughput in AI accelerators:
   - **Problem**: Weights and activations in neural networks are massive (GBs for modern LLMs)
   - **Solution**: Break data into tiles, use double-buffered scratchpad memory
   - **Benefit**: While MAC units compute on one buffer's data, DMA fetches the next tile into the other buffer, ensuring the MAC unit is always busy

3. **Memory Hierarchy Design**: This task demonstrates the critical memory subsystem patterns used in production TPUs:
   - DMA command/completion protocols (similar to AMBA AXI)
   - Scratchpad memory management
   - Ready/Valid handshaking (standard in on-chip interconnects)

4. **Protocol Compliance**: Real hardware must meet strict protocol requirements - the atomicity constraint (`mac_act_vld == mac_wgt_vld` at all times) reflects real-world synchronization requirements in systolic array designs.

## Codebase Description

### Directory Structure

```
grandmaster-repo/
├── docs/
│   └── specification.md    # Detailed task specification
├── sources/
│   ├── pkg_orchestrator.sv # Package with types and helper functions
│   └── TPU_double_buffering.sv  # Main orchestrator module (implementation)
├── tests/
│   └── test_golden_hidden_tough.py  # CocoTB testbench (hidden grader)
└── sim_build/              # Simulation output files
```

### Architecture Overview

```
                     ┌─────────────────────────────────────┐
                     │         ORCHESTRATOR                │
                     │                                      │
    start ──────────►│  ┌──────────┐     ┌─────────────┐   │
    tiles_total ────►│  │  State   │────►│ DMA Command │──────► dma_cmd_vld/desc/tag
                     │  │ Machine  │     │  Generator  │◄──────  dma_cmd_rdy
                     │  └──────────┘     └─────────────┘   │◄───  dma_credit_ok
                     │       │                  ▲          │◄───  dma_done_vld/tag
                     │       │                  │          │
                     │       ▼                  │          │
                     │  ┌──────────┐     ┌─────────────┐   │
                     │  │ Dispatch │────►│ Completion  │   │
                     │  │  Logic   │     │  Tracking   │   │
                     │  └──────────┘     └─────────────┘   │
                     │       │                             │
    mac_act_rdy ────►│       ▼                             │
    mac_wgt_rdy ────►│  ┌──────────┐                       │
                     │  │   MAC    │──────────────────────────► mac_act_vld/data
                     │  │Interface │──────────────────────────► mac_wgt_vld/data
                     │  └──────────┘                       │
                     │                                      │
    tiles_done ◄────│──────────────────────────────────────│
                     └─────────────────────────────────────┘
```

### Key Components

1. **pkg_orchestrator.sv**: Defines the data types and helper functions
   - `dma2d_desc_t`: 136-bit DMA descriptor structure (base address, dimensions, strides)
   - `tag_t`: Tag structure for identifying DMA transfers (operand type, buffer index, tile ID)
   - `pack_tag()` / `unpack_tag()`: Functions for tag encoding/decoding

2. **TPU_double_buffering.sv**: The main orchestrator module implementing:
   - 7-state FSM: IDLE → WAIT_CREDIT_ACT → ISSUE_ACT → WAIT_CREDIT_WGT → ISSUE_WGT → WAIT_DMA → DISPATCH
   - DMA command generation with ready/valid handshaking
   - Completion tracking for ACT and WGT transfers
   - MAC dispatch with atomic valid assertion

### Protocol Interfaces

| Interface | Type | Description |
|-----------|------|-------------|
| DMA Command | Ready/Valid + Credit | Issue 2D DMA descriptors with flow control |
| DMA Completion | Valid + Tag | Receive completion notifications |
| MAC Activation | Ready/Valid | Stream activation data to MAC array |
| MAC Weight | Ready/Valid | Stream weight data to MAC array |
| Scratchpad | Ready/Valid | Interface to on-chip SRAM (tied inactive) |

## Implementation Highlights

The golden solution demonstrates several key RTL design patterns:

1. **Atomic MAC Signaling**: Both MAC valid signals driven from single register
2. **DMA Credit Gating**: State machine waits for credit before asserting valid
3. **Separate Handshake Tracking**: Independent completion flags for ACT and WGT
4. **Proper Reset Behavior**: All registers cleared on active-low reset
5. **Robust State Transitions**: Clear next-state logic with default handler
