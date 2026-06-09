module ALU #(
    parameter ALU_CONTROL_BITS = 6
) (
    input  wire clk,
    input  wire reset,
    input  wire [31:0] dataA,
    input  wire [31:0] dataB,
    input  wire [ALU_CONTROL_BITS-1:0] ALUControl,

    output wire busy,
    output wire done,
    output reg  [31:0] dataOut,
    output reg  exceptionRaised
);
    localparam [ALU_CONTROL_BITS-1:0] ADD  = 6'b0_0_1_000;
    localparam [ALU_CONTROL_BITS-1:0] SUB  = 6'b0_0_1_001;
    localparam [ALU_CONTROL_BITS-1:0] XORR = 6'b0_0_0_000;
    localparam [ALU_CONTROL_BITS-1:0] ORR  = 6'b0_0_0_001;
    localparam [ALU_CONTROL_BITS-1:0] ANDD = 6'b0_0_0_010;
    localparam [ALU_CONTROL_BITS-1:0] SLL  = 6'b0_0_0_100;
    localparam [ALU_CONTROL_BITS-1:0] SRL  = 6'b0_0_0_101;
    localparam [ALU_CONTROL_BITS-1:0] SRA  = 6'b0_1_0_000;
    localparam [ALU_CONTROL_BITS-1:0] SLT  = 6'b0_0_1_111;
    localparam [ALU_CONTROL_BITS-1:0] SLTU = 6'b1_0_1_111;
    localparam [ALU_CONTROL_BITS-1:0] MUL  = 6'b0_0_1_010;
    localparam [ALU_CONTROL_BITS-1:0] MULU = 6'b1_0_1_010;
    localparam [ALU_CONTROL_BITS-1:0] MULH = 6'b0_0_1_011;
    localparam [ALU_CONTROL_BITS-1:0] MULHU= 6'b1_0_1_011;
    localparam [ALU_CONTROL_BITS-1:0] DIV  = 6'b0_0_1_100;
    localparam [ALU_CONTROL_BITS-1:0] DIVU = 6'b1_0_1_100;
    localparam [ALU_CONTROL_BITS-1:0] REM  = 6'b0_0_1_101;
    localparam [ALU_CONTROL_BITS-1:0] REMU = 6'b1_0_1_101;
    localparam [ALU_CONTROL_BITS-1:0] FADD = 6'b0_1_1_000;
    localparam [ALU_CONTROL_BITS-1:0] FSUB = 6'b0_1_1_001;
    localparam [ALU_CONTROL_BITS-1:0] FMUL = 6'b0_1_1_010;
    localparam [ALU_CONTROL_BITS-1:0] FDIV = 6'b0_1_1_100;
    localparam [ALU_CONTROL_BITS-1:0] FSLT = 6'b0_1_1_111;
    localparam [ALU_CONTROL_BITS-1:0] FCTI = 6'b0_1_0_001;
    localparam [ALU_CONTROL_BITS-1:0] ICTF = 6'b0_1_0_010;
    localparam [ALU_CONTROL_BITS-1:0] BEQ  = 6'b1_1_0_000;
    localparam [ALU_CONTROL_BITS-1:0] BNE  = 6'b1_1_0_001;
    localparam [ALU_CONTROL_BITS-1:0] BLT  = 6'b1_1_0_010;
    localparam [ALU_CONTROL_BITS-1:0] BGE  = 6'b1_1_0_011;
    localparam [ALU_CONTROL_BITS-1:0] BLTU = 6'b1_1_0_100;
    localparam [ALU_CONTROL_BITS-1:0] BGEU = 6'b1_1_0_101;

    wire [31:0] fadd_out;
    wire fadd_exception;
    wire [31:0] fcti_out;
    wire fcti_exception;
    wire [31:0] ictf_out;

    fp_addsub fp_addsub_u (
        .dataA(dataA),
        .dataB(dataB),
        .is_sub(ALUControl == FSUB),
        .dataOut(fadd_out),
        .exceptionRaised(fadd_exception)
    );

    fpToInt fp_to_int_u (
        .dataIn(dataA),
        .dataOut(fcti_out),
        .exceptionRaised(fcti_exception)
    );

    intToFp int_to_fp_u (
        .dataIn(dataA),
        .dataOut(ictf_out)
    );

    assign busy = 1'b0;
    assign done = 1'b1;

    always @(*) begin
        dataOut = 32'd0;
        exceptionRaised = 1'b0;

        case (ALUControl)
            ADD  : dataOut = dataA + dataB;
            SUB  : dataOut = dataA - dataB;
            XORR : dataOut = dataA ^ dataB;
            ORR  : dataOut = dataA | dataB;
            ANDD : dataOut = dataA & dataB;
            SLL  : dataOut = dataA << dataB[4:0];
            SRL  : dataOut = dataA >> dataB[4:0];
            SRA  : dataOut = $signed(dataA) >>> dataB[4:0];
            SLT  : dataOut = ($signed(dataA) < $signed(dataB)) ? 32'd1 : 32'd0;
            SLTU : dataOut = (dataA < dataB) ? 32'd1 : 32'd0;
            MUL  : dataOut = $signed(dataA) * $signed(dataB);
            MULU : dataOut = dataA * dataB;
            MULH : dataOut = ($signed(dataA) * $signed(dataB)) >>> 32;
            MULHU: dataOut = (dataA * dataB) >> 32;
            DIV  : begin
                if (dataB == 32'd0) begin
                    dataOut = 32'hFFFF_FFFF;
                    exceptionRaised = 1'b1;
                end else begin
                    dataOut = $signed(dataA) / $signed(dataB);
                end
            end
            DIVU : begin
                if (dataB == 32'd0) begin
                    dataOut = 32'hFFFF_FFFF;
                    exceptionRaised = 1'b1;
                end else begin
                    dataOut = dataA / dataB;
                end
            end
            REM  : begin
                if (dataB == 32'd0) begin
                    dataOut = dataA;
                    exceptionRaised = 1'b1;
                end else begin
                    dataOut = $signed(dataA) % $signed(dataB);
                end
            end
            REMU : begin
                if (dataB == 32'd0) begin
                    dataOut = dataA;
                    exceptionRaised = 1'b1;
                end else begin
                    dataOut = dataA % dataB;
                end
            end

            FADD, FSUB: begin
                dataOut = fadd_out;
                exceptionRaised = fadd_exception;
            end
            FMUL : dataOut = dataA * dataB;
            FDIV : begin
                if (dataB == 32'd0) begin
                    dataOut = 32'h7FC0_0000;
                    exceptionRaised = 1'b1;
                end else begin
                    dataOut = dataA / dataB;
                end
            end
            FSLT : dataOut = (dataA < dataB) ? 32'd1 : 32'd0;
            FCTI : begin
                dataOut = fcti_out;
                exceptionRaised = fcti_exception;
            end
            ICTF : dataOut = ictf_out;

            BEQ  : dataOut = (dataA == dataB) ? 32'd1 : 32'd0;
            BNE  : dataOut = (dataA != dataB) ? 32'd1 : 32'd0;
            BLT  : dataOut = ($signed(dataA) < $signed(dataB)) ? 32'd1 : 32'd0;
            BGE  : dataOut = ($signed(dataA) >= $signed(dataB)) ? 32'd1 : 32'd0;
            BLTU : dataOut = (dataA < dataB) ? 32'd1 : 32'd0;
            BGEU : dataOut = (dataA >= dataB) ? 32'd1 : 32'd0;

            default: dataOut = 32'd0;
        endcase
    end
endmodule
