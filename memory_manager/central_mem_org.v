module central_mem_org (
    //some of these might be made into wire instead of reg
    input wire clk,
    input wire reset,

    //Inputs from the CPU
    input wire [31:0] data_from_CPU,
    input wire [31:0] data_address_from_CPU,
    input wire wr_en_in,

    //Outputs to the CPU
    output reg [31:0] data_to_CPU,
    output reg busy,
    output reg done,

    //Outputs to the L1 cache
    output reg L1_enable,
    output reg [31:0] data_to_L1,
    output reg [31:0] data_address_to_L1, //Maybe we can make this wire only
    output reg wr_en_L1,

    //Inputs/responses from L1
    input wire busy_L1,
    input wire done_L1,
    input wire hit_L1,

    //Outputs to L2
    output reg L2_enable,
    output reg [31:0] data_to_L2,
    output reg [31:0] data_address_to_L2, //Maybe we can make this wire only
    output reg wr_en_L2,

    //Inputs/responses from L2
    input wire busy_L2,
    input wire done_L2,
    input wire hit_L2,

    //Outputs to the RAM
    output reg RAM_enable,
    output reg [31:0] data_to_RAM,
    output reg [31:0] data_address_to_RAM, //Maybe we can make this wire only
    output reg wr_en_RAM,

    //Inputs/responses from L1
    input wire busy_RAM,
    input wire done_RAM,
);
    //Instead of making everything state wise, I can try to use combinational logic also since we have confidence in the inputs lasting 1 clock cycle or the similar
endmodule