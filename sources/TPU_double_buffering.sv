`timescale 1ns/1ps

module orchestrator
import pkg_orchestrator::*;
(
    input  logic         clk,
    input  logic         rstn,

    output logic         dma_cmd_vld,
    input  logic         dma_cmd_rdy,
    output dma2d_desc_t  dma_cmd_desc,
    output logic [15:0]  dma_cmd_tag,
    input  logic         dma_credit_ok,
    input  logic         dma_done_vld,
    input  logic [15:0]  dma_done_tag,

    output logic         sp_req_vld,
    input  logic         sp_req_rdy,
    output logic  [1:0]  sp_req_bank,
    output logic [31:0]  sp_req_addr,
    output logic [15:0]  sp_req_len,
    input  logic [255:0] sp_data,

    output logic         mac_act_vld,
    input  logic         mac_act_rdy,
    output logic [255:0] mac_act_data,
    output logic         mac_wgt_vld,
    input  logic         mac_wgt_rdy,
    output logic [255:0] mac_wgt_data,

    input  logic         start,
    input  logic  [7:0]  tiles_total,
    input  dma2d_desc_t  act_template,
    input  dma2d_desc_t  wgt_template,
    output logic [31:0]  tiles_done
);

    typedef enum logic [2:0] {
        IDLE, WAIT_CREDIT_ACT, ISSUE_ACT, WAIT_CREDIT_WGT, ISSUE_WGT, WAIT_DMA, DISPATCH
    } state_e;
    
    state_e state;
    
    logic [7:0]  total_tiles, current_tile;
    logic [31:0] completed_cnt;
    logic act_dma_done, wgt_dma_done;
    logic mac_valid_reg;
    logic act_hs_done_r, wgt_hs_done_r;
    logic [255:0] data_reg;
    
    // DMA command registers
    logic dma_cmd_valid_reg;
    dma2d_desc_t dma_cmd_reg;
    logic [15:0] dma_cmd_tag_reg;
    
    // Pre-compute DMA descriptors combinationally
    dma2d_desc_t act_desc, wgt_desc;
    logic [15:0] act_tag, wgt_tag;
    
    always_comb begin
        act_desc = act_template;
        act_desc.tile_id = current_tile;
        act_tag = {5'd0, 2'd0, 1'b0, current_tile};
        
        wgt_desc = wgt_template;
        wgt_desc.tile_id = current_tile;
        wgt_tag = {5'd0, 2'd1, 1'b0, current_tile};
    end
    
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state            <= IDLE;
            total_tiles      <= 8'd0;
            current_tile     <= 8'd0;
            completed_cnt    <= 32'd0;
            act_dma_done     <= 1'b0;
            wgt_dma_done     <= 1'b0;
            mac_valid_reg    <= 1'b0;
            act_hs_done_r    <= 1'b0;
            wgt_hs_done_r    <= 1'b0;
            data_reg         <= '0;
            dma_cmd_valid_reg <= 1'b0;
            dma_cmd_reg      <= '0;
            dma_cmd_tag_reg  <= 16'h0;
        end else begin
            // DMA completion tracking (always active, all states)
            if (dma_done_vld) begin
                if (dma_done_tag[10:9] == 2'd0)
                    act_dma_done <= 1'b1;
                else if (dma_done_tag[10:9] == 2'd1)
                    wgt_dma_done <= 1'b1;
            end
            
            case (state)
                IDLE: begin
                    dma_cmd_valid_reg <= 1'b0;
                    if (start) begin
                        total_tiles   <= tiles_total;
                        current_tile  <= 8'd0;
                        completed_cnt <= 32'd0;
                        act_dma_done  <= 1'b0;
                        wgt_dma_done  <= 1'b0;
                        state         <= WAIT_CREDIT_ACT;
                    end
                end
                
                WAIT_CREDIT_ACT: begin
                    // Wait for credit, then assert valid
                    if (dma_credit_ok) begin
                        dma_cmd_valid_reg <= 1'b1;
                        dma_cmd_reg       <= act_desc;
                        dma_cmd_tag_reg   <= act_tag;
                        state             <= ISSUE_ACT;
                    end
                end
                
                ISSUE_ACT: begin
                    // Hold valid high until ready handshake
                    if (dma_cmd_rdy) begin
                        dma_cmd_valid_reg <= 1'b0;
                        state <= WAIT_CREDIT_WGT;
                    end
                    // valid_reg stays 1, cmd/tag stay stable
                end
                
                WAIT_CREDIT_WGT: begin
                    if (dma_credit_ok) begin
                        dma_cmd_valid_reg <= 1'b1;
                        dma_cmd_reg       <= wgt_desc;
                        dma_cmd_tag_reg   <= wgt_tag;
                        state             <= ISSUE_WGT;
                    end
                end
                
                ISSUE_WGT: begin
                    if (dma_cmd_rdy) begin
                        dma_cmd_valid_reg <= 1'b0;
                        state <= WAIT_DMA;
                    end
                end
                
                WAIT_DMA: begin
                    if (act_dma_done && wgt_dma_done) begin
                        mac_valid_reg <= 1'b1;
                        act_hs_done_r <= 1'b0;
                        wgt_hs_done_r <= 1'b0;
                        data_reg      <= sp_data;
                        state         <= DISPATCH;
                    end
                end
                
                DISPATCH: begin
                    // Track handshakes
                    if (mac_valid_reg && mac_act_rdy)
                        act_hs_done_r <= 1'b1;
                    if (mac_valid_reg && mac_wgt_rdy)
                        wgt_hs_done_r <= 1'b1;
                    
                    // Both handshakes done
                    if (act_hs_done_r && wgt_hs_done_r) begin
                        mac_valid_reg <= 1'b0;
                        completed_cnt <= completed_cnt + 1;
                        act_dma_done  <= 1'b0;
                        wgt_dma_done  <= 1'b0;
                        current_tile  <= current_tile + 1;
                        
                        if (completed_cnt + 1 >= total_tiles)
                            state <= IDLE;
                        else
                            state <= WAIT_CREDIT_ACT;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end
    
    // DMA outputs
    assign dma_cmd_vld  = dma_cmd_valid_reg;
    assign dma_cmd_desc = dma_cmd_reg;
    assign dma_cmd_tag  = dma_cmd_tag_reg;
    
    // MAC outputs - atomic
    assign mac_act_vld  = mac_valid_reg;
    assign mac_wgt_vld  = mac_valid_reg;
    assign mac_act_data = data_reg;
    assign mac_wgt_data = data_reg;
    
    // Scratchpad
    assign sp_req_vld  = 1'b0;
    assign sp_req_bank  = 2'b0;
    assign sp_req_addr  = 32'h0;
    assign sp_req_len   = 16'h1;
    
    assign tiles_done = completed_cnt;

endmodule