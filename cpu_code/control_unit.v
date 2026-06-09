module control_unit #(
    parameter ALU_CONTROL_BITS = 6
) (
    input  wire [31:0] instruction,
    input  wire [31:0] pc,

    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output reg  [31:0] immediate,

    output reg         use_imm,
    output reg         src_a_is_pc,
    output reg         src_a_is_zero,
    output reg         is_float,
    output reg         is_rd_relevant,

    output reg         mem_enable,
    output reg         mem_write,
    output reg         jump,
    output reg         is_branch,
    output reg         is_jalr,
    output reg         write_pc_plus4,

    output reg  [1:0]  rob_type,
    output reg  [ALU_CONTROL_BITS-1:0] alu_control
);
    localparam [ALU_CONTROL_BITS-1:0] ALU_ADD  = 6'b0_0_1_000;
    localparam [ALU_CONTROL_BITS-1:0] ALU_SUB  = 6'b0_0_1_001;
    localparam [ALU_CONTROL_BITS-1:0] ALU_XOR  = 6'b0_0_0_000;
    localparam [ALU_CONTROL_BITS-1:0] ALU_OR   = 6'b0_0_0_001;
    localparam [ALU_CONTROL_BITS-1:0] ALU_AND  = 6'b0_0_0_010;
    localparam [ALU_CONTROL_BITS-1:0] ALU_SLL  = 6'b0_0_0_100;
    localparam [ALU_CONTROL_BITS-1:0] ALU_SRL  = 6'b0_0_0_101;
    localparam [ALU_CONTROL_BITS-1:0] ALU_SRA  = 6'b0_1_0_000;
    localparam [ALU_CONTROL_BITS-1:0] ALU_SLT  = 6'b0_0_1_111;
    localparam [ALU_CONTROL_BITS-1:0] ALU_SLTU = 6'b1_0_1_111;
    localparam [ALU_CONTROL_BITS-1:0] ALU_MUL  = 6'b0_0_1_010;
    localparam [ALU_CONTROL_BITS-1:0] ALU_MULU = 6'b1_0_1_010;
    localparam [ALU_CONTROL_BITS-1:0] ALU_MULH = 6'b0_0_1_011;
    localparam [ALU_CONTROL_BITS-1:0] ALU_MULHU= 6'b1_0_1_011;
    localparam [ALU_CONTROL_BITS-1:0] ALU_DIV  = 6'b0_0_1_100;
    localparam [ALU_CONTROL_BITS-1:0] ALU_DIVU = 6'b1_0_1_100;
    localparam [ALU_CONTROL_BITS-1:0] ALU_REM  = 6'b0_0_1_101;
    localparam [ALU_CONTROL_BITS-1:0] ALU_REMU = 6'b1_0_1_101;
    localparam [ALU_CONTROL_BITS-1:0] ALU_FADD = 6'b0_1_1_000;
    localparam [ALU_CONTROL_BITS-1:0] ALU_FSUB = 6'b0_1_1_001;
    localparam [ALU_CONTROL_BITS-1:0] ALU_FMUL = 6'b0_1_1_010;
    localparam [ALU_CONTROL_BITS-1:0] ALU_FDIV = 6'b0_1_1_100;
    localparam [ALU_CONTROL_BITS-1:0] ALU_FSLT = 6'b0_1_1_111;
    localparam [ALU_CONTROL_BITS-1:0] ALU_FCTI = 6'b0_1_0_001;
    localparam [ALU_CONTROL_BITS-1:0] ALU_ICTF = 6'b0_1_0_010;
    localparam [ALU_CONTROL_BITS-1:0] ALU_BEQ  = 6'b1_1_0_000;
    localparam [ALU_CONTROL_BITS-1:0] ALU_BNE  = 6'b1_1_0_001;
    localparam [ALU_CONTROL_BITS-1:0] ALU_BLT  = 6'b1_1_0_010;
    localparam [ALU_CONTROL_BITS-1:0] ALU_BGE  = 6'b1_1_0_011;
    localparam [ALU_CONTROL_BITS-1:0] ALU_BLTU = 6'b1_1_0_100;
    localparam [ALU_CONTROL_BITS-1:0] ALU_BGEU = 6'b1_1_0_101;

    wire [6:0] opcode = instruction[6:0];
    wire [2:0] funct3 = instruction[14:12];
    wire [6:0] funct7 = instruction[31:25];

    assign rs1 = instruction[19:15];
    assign rs2 = instruction[24:20];
    assign rd  = instruction[11:7];

    wire [31:0] imm_i = {{20{instruction[31]}}, instruction[31:20]};
    wire [31:0] imm_s = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};
    wire [31:0] imm_b = {{19{instruction[31]}}, instruction[31], instruction[7], instruction[30:25], instruction[11:8], 1'b0};
    wire [31:0] imm_u = {instruction[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instruction[31]}}, instruction[31], instruction[19:12], instruction[20], instruction[30:21], 1'b0};

    always @(*) begin
        immediate      = 32'd0;
        use_imm        = 1'b0;
        src_a_is_pc    = 1'b0;
        src_a_is_zero  = 1'b0;
        is_float       = 1'b0;
        is_rd_relevant = 1'b0;
        mem_enable     = 1'b0;
        mem_write      = 1'b0;
        jump           = 1'b0;
        is_branch      = 1'b0;
        is_jalr        = 1'b0;
        write_pc_plus4 = 1'b0;
        rob_type       = 2'b10;
        alu_control    = ALU_ADD;

        case (opcode)
            7'b0110011: begin
                is_rd_relevant = 1'b1;
                case ({funct7, funct3})
                    10'b0000000_000: alu_control = ALU_ADD;
                    10'b0100000_000: alu_control = ALU_SUB;
                    10'b0000000_100: alu_control = ALU_XOR;
                    10'b0000000_110: alu_control = ALU_OR;
                    10'b0000000_111: alu_control = ALU_AND;
                    10'b0000000_001: alu_control = ALU_SLL;
                    10'b0000000_101: alu_control = ALU_SRL;
                    10'b0100000_101: alu_control = ALU_SRA;
                    10'b0000000_010: alu_control = ALU_SLT;
                    10'b0000000_011: alu_control = ALU_SLTU;
                    10'b0000001_000: alu_control = ALU_MUL;
                    10'b0000001_001: alu_control = ALU_MULH;
                    10'b0000001_010: alu_control = ALU_MULU;
                    10'b0000001_011: alu_control = ALU_MULHU;
                    10'b0000001_100: alu_control = ALU_DIV;
                    10'b0000001_101: alu_control = ALU_DIVU;
                    10'b0000001_110: alu_control = ALU_REM;
                    10'b0000001_111: alu_control = ALU_REMU;
                    default: alu_control = ALU_ADD;
                endcase
            end

            7'b0010011: begin
                is_rd_relevant = 1'b1;
                use_imm = 1'b1;
                immediate = imm_i;
                case (funct3)
                    3'b000: alu_control = ALU_ADD;
                    3'b010: alu_control = ALU_SLT;
                    3'b011: alu_control = ALU_SLTU;
                    3'b100: alu_control = ALU_XOR;
                    3'b110: alu_control = ALU_OR;
                    3'b111: alu_control = ALU_AND;
                    3'b001: alu_control = ALU_SLL;
                    3'b101: alu_control = instruction[30] ? ALU_SRA : ALU_SRL;
                    default: alu_control = ALU_ADD;
                endcase
            end

            7'b0000011: begin
                is_rd_relevant = 1'b1;
                use_imm = 1'b1;
                immediate = imm_i;
                mem_enable = 1'b1;
                mem_write = 1'b0;
                rob_type = 2'b11;
                alu_control = ALU_ADD;
            end

            7'b0100011: begin
                use_imm = 1'b1;
                immediate = imm_s;
                mem_enable = 1'b1;
                mem_write = 1'b1;
                rob_type = 2'b00;
                alu_control = ALU_ADD;
            end

            7'b1100011: begin
                use_imm = 1'b1;
                immediate = imm_b;
                jump = 1'b1;
                is_branch = 1'b1;
                rob_type = 2'b01;
                case (funct3)
                    3'b000: alu_control = ALU_BEQ;
                    3'b001: alu_control = ALU_BNE;
                    3'b100: alu_control = ALU_BLT;
                    3'b101: alu_control = ALU_BGE;
                    3'b110: alu_control = ALU_BLTU;
                    3'b111: alu_control = ALU_BGEU;
                    default: alu_control = ALU_BEQ;
                endcase
            end

            7'b1101111: begin
                is_rd_relevant = 1'b1;
                jump = 1'b1;
                write_pc_plus4 = 1'b1;
                src_a_is_pc = 1'b1;
                use_imm = 1'b1;
                immediate = imm_j;
                rob_type = 2'b01;
                alu_control = ALU_ADD;
            end

            7'b1100111: begin
                is_rd_relevant = 1'b1;
                jump = 1'b1;
                is_jalr = 1'b1;
                write_pc_plus4 = 1'b1;
                use_imm = 1'b1;
                immediate = imm_i;
                rob_type = 2'b01;
                alu_control = ALU_ADD;
            end

            7'b0110111: begin
                is_rd_relevant = 1'b1;
                src_a_is_zero = 1'b1;
                use_imm = 1'b1;
                immediate = imm_u;
                alu_control = ALU_ADD;
            end

            7'b0010111: begin
                is_rd_relevant = 1'b1;
                src_a_is_pc = 1'b1;
                use_imm = 1'b1;
                immediate = imm_u;
                alu_control = ALU_ADD;
            end

            7'b1010011: begin
                is_rd_relevant = 1'b1;
                is_float = 1'b1;
                case (funct7)
                    7'b0000000: alu_control = ALU_FADD;
                    7'b0000100: alu_control = ALU_FSUB;
                    7'b0001000: alu_control = ALU_FMUL;
                    7'b0001100: alu_control = ALU_FDIV;
                    7'b1010000: alu_control = ALU_FSLT;
                    7'b1100000: alu_control = ALU_FCTI;
                    7'b1101000: alu_control = ALU_ICTF;
                    default: alu_control = ALU_FADD;
                endcase
            end

            default: begin
            end
        endcase
    end
endmodule
