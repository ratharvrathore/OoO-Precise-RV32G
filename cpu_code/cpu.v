module cpu (
    input wire clk,
    input wire reset,
);
    //Reads will occur on the negative edges, writing and pushing on the positive edges
    //We have to write the control varibales from the instruction (purely combinational and carried forward by the regs)
    //We have to write the flush/next logic
    //We will not have data forwarding here

    //following values of localparams are subject to change
    localparam PRE_DECODE_REG_LEN = 64; //to be modified to appropiate amount
    localparam POST_EXECUTE_REG_LEN = 64;
    localparam POST_MEM_REG_KEN = 128;
    //Add other localparams

    //Variables
    wire [31:0] Pc, PcPlus4, NewPc, JumpPc;
    wire [31:0] instr;
    reg [PRE_DECODE_REG_LEN-1 : 0] fetch_reg;

    wire [4:0] Rs1, Rs2, Rd;
    wire floatOrNot;
    wire [31:0] regWriteData, data_Rs1, data_Rs2;
    wire available1, available2;
    wire [3:0] tag1, tag2;
    wire [3:0] next_tag;

    //control
    wire JumpCtrl;
    wire nextSignal_Fetch, flush;
    wire RegWrite, isRdRelevant;
    //Hardware instantiations

    .instr_cache instr_cache(
        .clk(clk),
        .instruction_address(Pc),
        .instruction(instr)
    );

    .reg_file reg_file(
        .Rs1(Rs1),
        .Rs2(Rs2),
        .Rd(Rd),
        .float(floatOrNot),
        .dataIn(regWriteData),
        .RegWrite(RegWrite),
        .clk(clk),
        .reset(reset),
        .next_tag(next_tag),
        .isRdRelevant(isRdRelevant),
        .data_Rs1(data_Rs1),
        .data_Rs2(data_Rs2),
        .available1(available1),
        .available2(available2),
        .tag1(tag1),
        .tag2(tag2)
    )
    //Fetch
    assign PcPlus4 = Pc + 32'd4;
    assign NewPc = (JumpCtrl) ? PcPlus4 : (JumpPc);
    always @(posedge clk) begin
        if(nextSignal_Fetch) begin
            Pc <= NewPc;
        end
    end
    always @(posedge clk or posedge flush) begin
        if (flush) begin
            fetch_reg <= 0;
        end else begin
            if (nextSignal_Fetch) begin
                fetch_reg[31:0] <= instruction;
                fetch_reg[63:32] <= PcPlus4;
                

                //And other instantiations of control variables, etc
            end
        end
    end

    //Decode


    //Schedule


    //Execute
    

    //Memory
    //Mostly combinational only
    //Add some input and output wires to the CPU for this, namely
    //inputs: busy, done, [31:0] data
    //You can trust the inputs will be held high appropiately, so need not sample them but send them directly to the POST_MEM_REG
    //outputs: address, wren, write data, enable wire


    //Reorder
    //Have the logic for choosing bw mem value and ALUout, followed by a bus which will connect to ROB and scheduler
    //If either ROB and scheduler have that tag mentioned in their regions they will update their values


    //Write back phase
    //From here we will have JumpCtrl and JumpPc both
    //ROB will also do its thing here as written in their respective files
endmodule