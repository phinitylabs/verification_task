`timescale 1ns/1ps

package pkg_orchestrator;
  typedef enum logic [1:0] {OP_ACT=2'd0, OP_WGT=2'd1} operand_e;
  
  typedef struct packed {
    logic [31:0] base;
    logic [15:0] rows;
    logic [15:0] cols;
    logic [31:0] row_stride;
    logic [15:0] bursts_per_row;
    logic [15:0] burst_len;
    logic [7:0]  tile_id;
  } dma2d_desc_t;

  typedef struct packed {
    operand_e   op;
    logic       buf_idx; 
    logic [7:0] tile_id; 
  } tag_t;

  function automatic logic [15:0] pack_tag(tag_t t);
    pack_tag = {5'd0, t.op, t.buf_idx, t.tile_id};
  endfunction

  function automatic tag_t unpack_tag(logic [15:0] x);
    tag_t t;
    t.op      = operand_e'(x[10:9]); 
    t.buf_idx = x[8];                
    t.tile_id = x[7:0];
    return t;
  endfunction
endpackage

interface rv_if(input logic clk, input logic rst_n);
    logic         valid;
    logic         ready;
    logic [255:0] data; 
    modport prod (input ready, output valid, output data);
    modport cons (input valid, input data, output ready);
endinterface