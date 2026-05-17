module central_mem_org (
    //some of these might be made into wire instead of reg
    input wire clk,
    input wire reset,

    //Inputs from the CPU
    input wire [31:0] data_from_CPU,
    input wire [31:0] data_address_from_CPU,
    input wire wr_en_in,
    input wire get_to_work,

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

    //variable instantiation
    reg [2:0] state;

    //Memory organization will be spred out as an FSM. We will look at L1 first, then L2, then RAM
    localparam IDLE = 3'd0;
    localparam L1_CHECK = 3'd1;
    localparam L2_CHECK = 3'd2;
    localparam RAM_CHECK = 3'd3;
    localparam DONE = 3'd4;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 0;
            done <= 0;
            L1_enable <= 0;
            wr_en_L1 <= 0;
            L2_enable <= 0;
            wr_en_L2 <= 0;
            RAM_enable <= 0;
            wr_en_RAM <= 0;
            state <= IDLE;
        end else begin
            case (state)
                IDLE : begin
                    done <= 0;
                    L1_enable <= 0;
                    wr_en_L1 <= 0;
                    L2_enable <= 0;
                    wr_en_L2 <= 0;
                    RAM_enable <= 0;
                    wr_en_RAM <= 0;
                    if()
                end
                L1_CHECK : begin
                    
                end
                L2_CHECK : begin
                    
                end
                RAM_CHECK : begin
                    
                end
                DONE : begin

                end
                default: 
            endcase
        end
    end

endmodule