# Orchestrator RTL Design Prompt

## Overview

You are tasked with designing a **tile orchestrator** module for a neural network accelerator in SystemVerilog. The orchestrator must coordinate DMA transfers and MAC unit dispatches for tile-based processing. The module should be named `orchestrator` and import the package `pkg_orchestrator` for necessary types.

**Key Files:**
- Design file: `sources/TPU_double_buffering.sv` (implement the `orchestrator` module here)
- Test file: `tests/test_golden_hidden_tough.py` (cocotb testbench)

The design must pass all test scenarios, which include various timing delays, credit denials, and protocol checks. Focus on correctness, especially the atomicity requirement.

## Interface Specification

All signals are active-high and synchronous to the rising edge of `clk`. Update the module ports to use the following naming conventions for clarity:

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `clk` | input | 1 | System clock |
| `rstn` | input | 1 | Active-low asynchronous reset |
| `dma_cmd_vld` | output | 1 | Valid command presented |
| `dma_cmd_rdy` | input | 1 | DMA ready to accept |
| `dma_cmd_desc` | output | 136 | DMA descriptor (`dma2d_desc_t`) |
| `dma_cmd_tag` | output | 16 | Tag identifying this transfer |
| `dma_credit_ok` | input | 1 | Credit available for issuing |
| `dma_done_vld` | input | 1 | Pulse when DMA completes |
| `dma_done_tag` | input | 16 | Tag of completed transfer |
| `sp_req_vld` | output | 1 | Scratchpad request valid |
| `sp_req_rdy` | input | 1 | Scratchpad ready |
| `sp_req_bank` | output | 2 | Bank selector |
| `sp_req_addr` | output | 32 | Address |
| `sp_req_len` | output | 16 | Length |
| `sp_data` | input | 256 | Data from scratchpad |
| `mac_act_vld` | output | 1 | ACT data valid |
| `mac_act_rdy` | input | 1 | MAC ready for ACT |
| `mac_act_data` | output | 256 | Activation data |
| `mac_wgt_vld` | output | 1 | WGT data valid |
| `mac_wgt_rdy` | input | 1 | MAC ready for WGT |
| `mac_wgt_data` | output | 256 | Weight data |
| `start` | input | 1 | Pulse to begin |
| `tiles_total` | input | 8 | Number of tiles |
| `act_template` | input | 136 | Template for ACT DMA |
| `wgt_template` | input | 136 | Template for WGT DMA |
| `tiles_done` | output | 32 | Completed tile count |

## Data Structures

### DMA Descriptor (`dma2d_desc_t`)

```systemverilog
typedef struct packed {
  logic [31:0] base;
  logic [15:0] rows;
  logic [15:0] cols;
  logic [31:0] row_stride;
  logic [15:0] bursts_per_row;
  logic [15:0] burst_len;
  logic [7:0]  tile_id;
} dma2d_desc_t;  // 136 bits
```

When issuing a DMA command, copy the appropriate template and update the `tile_id` field with the current tile number.

### Tag Format (16-bit)

| Bits | Field | Description |
|------|-------|-------------|
| [15:11] | Reserved | Must be 0 |
| [10:9] | op_type | 0=ACT, 1=WGT |
| [8] | buf_idx | Buffer index (use 0) |
| [7:0] | tile_id | Current tile ID |

Use bits [10:9] of `dma_done_tag` to determine if a completion is for ACT or WGT.

## Critical Requirements

### MAC Atomicity — STRICTLY ENFORCED

**`mac_act_vld` must ALWAYS equal `mac_wgt_vld` on EVERY clock cycle.**

Any single cycle where these differ causes immediate test failure. This means:
- Assert both together in the same cycle
- Deassert both together in the same cycle
- Never have one high while the other is low

### Ready/Valid Protocol

Standard AXI-Stream semantics apply to DMA and MAC interfaces:
- Once `vld` asserts, it **cannot deassert until `rdy` is seen**
- Data must remain **stable** while `vld=1` and `rdy=0`

### DMA Credit

Check `dma_credit_ok` before asserting `dma_cmd_vld`. Credit may be denied for 1-3 consecutive cycles randomly.

### Counter Rules

- `tiles_done` must never decrease
- `tiles_done` may only increment by 1
- Increment only after a tile is fully complete

## Operation

### Startup

When `start` pulses, capture `tiles_total` and begin processing from tile 0.

### Per-Tile Sequence

For each tile:

1. **Issue ACT DMA**: Wait for credit, then issue command with op_type=0 and current tile_id. Hold vld until rdy handshake completes.

2. **Issue WGT DMA**: Wait for credit, then issue command with op_type=1 and current tile_id. Hold vld until rdy handshake completes.

3. **Wait for completions**: Monitor `dma_done_vld` and decode `dma_done_tag` bits [10:9] to identify ACT (0) vs WGT (1). Both must complete before proceeding. Completions may arrive in any order.

4. **Dispatch to MAC**: Assert both MAC vlds simultaneously with `sp_data`.

5. **Complete handshakes**: Wait for BOTH `mac_act_rdy` AND `mac_wgt_rdy`. These arrive independently at different times. Keep both vlds asserted until both handshakes complete.

6. **Finish tile**: Deassert both vlds together, increment `tiles_done`.

### Completion

Return to idle when `tiles_done` equals `tiles_total`.

## Testbench Behavior

The cocotb testbench includes:
- **Credit denial**: `dma_credit_ok` randomly denied for 1-3 cycle streaks (~30% of cycles)
- **DMA completions**: Arrive after random delay, in any order (ACT first, WGT first, or same cycle)
- **MAC ACT rdy**: Delayed 1-7 cycles after vld asserts
- **MAC WGT rdy**: Delayed 2-7 cycles after vld asserts (independent of ACT)

The testbench checks every cycle:
- Atomicity: `mac_act_vld == mac_wgt_vld`
- Protocol: vld doesn't drop before rdy, data stable during stall
- Counter: never decreases, never jumps

## Hints

- Scratchpad interface is unused in basic operation; tie request outputs to inactive defaults
- DMA completions can arrive in any order — track both separately
- MAC rdy signals are independent — one may arrive much later than the other
- The atomicity rule means both MAC vlds must be controlled together
- Think about state machines: IDLE, WAIT_CREDIT_ACT, ISSUE_ACT, WAIT_CREDIT_WGT, ISSUE_WGT, WAIT_DMA, DISPATCH
- Use combinational logic for descriptor preparation
- Ensure proper reset behavior

## Brief Example

Processing tile 0:
```
1. Wait for credit, issue ACT DMA (tag with op=0, tile=0)
2. Wait for credit, issue WGT DMA (tag with op=1, tile=0)
3. Wait... dma_done_vld pulses with tag showing op=1 (WGT done)
4. Wait... dma_done_vld pulses with tag showing op=0 (ACT done)
5. Both done -> assert mac_act_vld=1, mac_wgt_vld=1, data=sp_data
6. Cycle N: mac_act_rdy=1, mac_wgt_rdy=0 (keep both vlds HIGH)
7. Cycle N+1: mac_act_rdy=1, mac_wgt_rdy=0 (keep both vlds HIGH)
8. Cycle N+2: mac_wgt_rdy=1 (now both done, can deassert)
9. Deassert both vlds, tiles_done=1, move to tile 1
```

## Notes

- Focus on correctness over optimization
- The atomicity rule is the most common failure point
- Think carefully about the MAC dispatch state: what happens when rdy signals arrive at different times?
- The test file uses `toplevel="orchestrator"` in the run function
- Ensure all signal names match exactly as specified
- The design should be synthesizable and follow good RTL practices
