module cpu (
    input  wire clk,
    input  wire reset,

    input  wire mem_busy,
    input  wire mem_done,
    input  wire [31:0] mem_read_data,

    output reg  [31:0] mem_address,
    output reg  mem_wren,
    output reg  [31:0] mem_write_data,
    output reg  mem_enable
);
    localparam ALU_CONTROL_BITS = 6;
    localparam SCHEDULER_TAG_BITS = 3;
    localparam REORDER_TAG_BITS = 4;

    reg [31:0] pc;
    wire [31:0] instruction;
    wire [31:0] pc_plus4 = pc + 32'd4;

    reg [31:0] fetch_instr;
    reg [31:0] fetch_pc;
    reg [31:0] fetch_pc_plus4;
    reg fetch_valid;

    wire [4:0] rs1_dec;
    wire [4:0] rs2_dec;
    wire [4:0] rd_dec;
    wire [31:0] imm_dec;
    wire use_imm_dec;
    wire src_a_is_pc_dec;
    wire src_a_is_zero_dec;
    wire is_float_dec;
    wire is_rd_relevant_dec;
    wire mem_enable_dec;
    wire mem_write_dec;
    wire jump_dec;
    wire is_branch_dec;
    wire is_jalr_dec;
    wire write_pc_plus4_dec;
    wire [1:0] rob_type_dec;
    wire [ALU_CONTROL_BITS-1:0] alu_control_dec;

    wire [31:0] reg_data_rs1;
    wire [31:0] reg_data_rs2;
    wire reg_avail1;
    wire reg_avail2;
    wire [REORDER_TAG_BITS-1:0] reg_tag1;
    wire [REORDER_TAG_BITS-1:0] reg_tag2;

    wire [31:0] rob_data_a;
    wire [31:0] rob_data_b;
    wire [SCHEDULER_TAG_BITS-1:0] rob_sch_tag_a;
    wire [SCHEDULER_TAG_BITS-1:0] rob_sch_tag_b;
    wire rob_valid_a;
    wire rob_valid_b;

    wire rob_full;
    wire rob_empty;
    wire [REORDER_TAG_BITS-1:0] rob_next_tag;
    wire [31:0] rob_wb_data;
    wire [4:0] rob_wb_rd;
    wire rob_wb_en;

    wire sch_full;
    wire sch_empty;
    wire [SCHEDULER_TAG_BITS-1:0] sch_next_tag;
    wire [31:0] sch_issue_a;
    wire [31:0] sch_issue_b;
    wire [SCHEDULER_TAG_BITS-1:0] sch_issue_tag;
    wire [ALU_CONTROL_BITS-1:0] sch_issue_ctrl;
    wire sch_issue_mem_en;
    wire sch_issue_mem_wr;
    wire sch_issue_jump;

    wire [31:0] src_a_selected = src_a_is_zero_dec ? 32'd0 :
                                 src_a_is_pc_dec   ? fetch_pc :
                                 (reg_avail1       ? reg_data_rs1 :
                                 (rob_valid_a      ? rob_data_a : 32'd0));

    wire [31:0] src_b_reg_selected = reg_avail2 ? reg_data_rs2 :
                                     (rob_valid_b ? rob_data_b : 32'd0);
    wire [31:0] src_b_selected = use_imm_dec ? imm_dec : src_b_reg_selected;

    wire src_a_ready = src_a_is_zero_dec || src_a_is_pc_dec || reg_avail1 || rob_valid_a;
    wire src_b_ready = use_imm_dec || reg_avail2 || rob_valid_b;

    wire [SCHEDULER_TAG_BITS-1:0] src_a_tag = (reg_avail1 || rob_valid_a || src_a_is_zero_dec || src_a_is_pc_dec) ? {SCHEDULER_TAG_BITS{1'b0}} : rob_sch_tag_a;
    wire [SCHEDULER_TAG_BITS-1:0] src_b_tag = (src_b_ready) ? {SCHEDULER_TAG_BITS{1'b0}} : rob_sch_tag_b;

    reg execute_valid;
    reg [31:0] execute_result;
    reg execute_exception;
    reg [SCHEDULER_TAG_BITS-1:0] execute_tag;
    reg execute_mem_en;
    reg execute_mem_wr;
    reg execute_jump;
    reg execute_branch;
    reg execute_write_pc_plus4;
    reg [31:0] execute_pc_plus4;
    reg [31:0] execute_data_b;
    reg [ALU_CONTROL_BITS-1:0] execute_ctrl;

    reg mem_stage_valid;
    reg [31:0] mem_stage_value;
    reg mem_stage_exception;
    reg [SCHEDULER_TAG_BITS-1:0] mem_stage_tag;

    reg [31:0] jump_target;
    reg jump_valid;

    wire push_fetch;
    wire push_schedule;
    wire push_reorder;
    wire advance_fetch;

    wire [31:0] alu_data_out;
    wire alu_busy;
    wire alu_done;
    wire alu_exception;

    wire [31:0] reorder_broadcast_data = mem_stage_value;
    wire [SCHEDULER_TAG_BITS-1:0] reorder_broadcast_tag = mem_stage_tag;

    wire branch_ctrl = (execute_ctrl == 6'b1_1_0_000) ||
                       (execute_ctrl == 6'b1_1_0_001) ||
                       (execute_ctrl == 6'b1_1_0_010) ||
                       (execute_ctrl == 6'b1_1_0_011) ||
                       (execute_ctrl == 6'b1_1_0_100) ||
                       (execute_ctrl == 6'b1_1_0_101);

    instr_cache instr_cache_u (
        .clk(clk),
        .instruction_address(pc),
        .instruction(instruction)
    );

    control_unit #(
        .ALU_CONTROL_BITS(ALU_CONTROL_BITS)
    ) control_unit_u (
        .instruction(fetch_instr),
        .pc(fetch_pc),
        .rs1(rs1_dec),
        .rs2(rs2_dec),
        .rd(rd_dec),
        .immediate(imm_dec),
        .use_imm(use_imm_dec),
        .src_a_is_pc(src_a_is_pc_dec),
        .src_a_is_zero(src_a_is_zero_dec),
        .is_float(is_float_dec),
        .is_rd_relevant(is_rd_relevant_dec),
        .mem_enable(mem_enable_dec),
        .mem_write(mem_write_dec),
        .jump(jump_dec),
        .is_branch(is_branch_dec),
        .is_jalr(is_jalr_dec),
        .write_pc_plus4(write_pc_plus4_dec),
        .rob_type(rob_type_dec),
        .alu_control(alu_control_dec)
    );

    reg_file reg_file_u (
        .Rs1(rs1_dec),
        .Rs2(rs2_dec),
        .RdDecode(rd_dec),
        .RdWrite(rob_wb_rd),
        .float(is_float_dec),
        .dataIn(rob_wb_data),
        .RegWrite(rob_wb_en),
        .clk(clk),
        .reset(reset),
        .next_tag(rob_next_tag),
        .isRdRelevant(push_fetch && is_rd_relevant_dec),
        .data_Rs1(reg_data_rs1),
        .data_Rs2(reg_data_rs2),
        .available1(reg_avail1),
        .available2(reg_avail2),
        .tag1(reg_tag1),
        .tag2(reg_tag2)
    );

    scheduler #(
        .SCHEDULER_TAG_BITS(SCHEDULER_TAG_BITS),
        .ALU_CONTROL_BITS(ALU_CONTROL_BITS)
    ) scheduler_u (
        .clk(clk),
        .reset(reset),
        .full(sch_full),
        .empty(sch_empty),
        .dataAIn(src_a_selected),
        .dataBIn(src_b_selected),
        .tagAIn(src_a_tag),
        .tagBIn(src_b_tag),
        .availableA(src_a_ready),
        .availableB(src_b_ready),
        .memEnIn(mem_enable_dec),
        .memWrEnIn(mem_write_dec),
        .jumpIn(jump_dec),
        .aluControlIn(alu_control_dec),
        .push_fetch(push_fetch),
        .push_schdule(push_schedule),
        .push_reorder(push_reorder),
        .broadcastData(reorder_broadcast_data),
        .broadcastTag(reorder_broadcast_tag),
        .dataOutA(sch_issue_a),
        .dataOutB(sch_issue_b),
        .tagOut(sch_issue_tag),
        .aluControlOut(sch_issue_ctrl),
        .memEnOut(sch_issue_mem_en),
        .memWrEnOut(sch_issue_mem_wr),
        .jumpOut(sch_issue_jump),
        .nextSchTag(sch_next_tag)
    );

    reorder_buffer #(
        .SCHEDULER_TAG_BITS(SCHEDULER_TAG_BITS),
        .REORDER_TAG_BITS(REORDER_TAG_BITS)
    ) reorder_buffer_u (
        .clk(clk),
        .reset(reset),
        .full(rob_full),
        .empty(rob_empty),
        .typeIn(rob_type_dec),
        .rdIn(rd_dec),
        .memAddrIn(execute_result),
        .dataIn(reorder_broadcast_data),
        .pcPlus4In(fetch_pc_plus4),
        .exceptionFlagIn(mem_stage_exception),
        .nextSchTag(sch_next_tag),
        .tagA(reg_tag1),
        .tagB(reg_tag2),
        .push_fetch(push_fetch),
        .push_reorder(push_reorder),
        .broadcastSchTag(reorder_broadcast_tag),
        .dataOutReg(rob_wb_data),
        .rdOut(rob_wb_rd),
        .regWrEn(rob_wb_en),
        .broadcastNextTag(rob_next_tag),
        .dataOutA(rob_data_a),
        .dataOutB(rob_data_b),
        .schTagA(rob_sch_tag_a),
        .schTagB(rob_sch_tag_b),
        .validA(rob_valid_a),
        .validB(rob_valid_b)
    );

    ALU #(
        .ALU_CONTROL_BITS(ALU_CONTROL_BITS)
    ) alu_u (
        .clk(clk),
        .reset(reset),
        .dataA(sch_issue_a),
        .dataB(sch_issue_b),
        .ALUControl(sch_issue_ctrl),
        .busy(alu_busy),
        .done(alu_done),
        .dataOut(alu_data_out),
        .exceptionRaised(alu_exception)
    );

    push_controller push_controller_u (
        .fetch_valid(fetch_valid && src_a_ready && src_b_ready),
        .scheduler_full(sch_full),
        .rob_full(rob_full),
        .scheduler_empty(sch_empty),
        .alu_busy(alu_busy),
        .execute_valid(mem_stage_valid),
        .mem_required(execute_mem_en),
        .mem_done(mem_done),
        .push_fetch(push_fetch),
        .push_schedule(push_schedule),
        .push_reorder(push_reorder),
        .advance_fetch(advance_fetch)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pc <= 32'd0;
            fetch_instr <= 32'd0;
            fetch_pc <= 32'd0;
            fetch_pc_plus4 <= 32'd0;
            fetch_valid <= 1'b0;
            execute_valid <= 1'b0;
            execute_result <= 32'd0;
            execute_exception <= 1'b0;
            execute_tag <= {SCHEDULER_TAG_BITS{1'b0}};
            execute_mem_en <= 1'b0;
            execute_mem_wr <= 1'b0;
            execute_jump <= 1'b0;
            execute_branch <= 1'b0;
            execute_write_pc_plus4 <= 1'b0;
            execute_pc_plus4 <= 32'd0;
            execute_data_b <= 32'd0;
            execute_ctrl <= {ALU_CONTROL_BITS{1'b0}};
            mem_stage_valid <= 1'b0;
            mem_stage_value <= 32'd0;
            mem_stage_exception <= 1'b0;
            mem_stage_tag <= {SCHEDULER_TAG_BITS{1'b0}};
            jump_target <= 32'd0;
            jump_valid <= 1'b0;
            mem_address <= 32'd0;
            mem_wren <= 1'b0;
            mem_write_data <= 32'd0;
            mem_enable <= 1'b0;
        end else begin
            jump_valid <= 1'b0;

            if (advance_fetch || !fetch_valid) begin
                fetch_instr <= instruction;
                fetch_pc <= pc;
                fetch_pc_plus4 <= pc_plus4;
                fetch_valid <= 1'b1;
                pc <= jump_valid ? jump_target : pc_plus4;
            end else if (jump_valid) begin
                pc <= jump_target;
                fetch_valid <= 1'b0;
            end

            if (push_schedule) begin
                execute_valid <= 1'b1;
                execute_result <= alu_data_out;
                execute_exception <= alu_exception;
                execute_tag <= sch_issue_tag;
                execute_mem_en <= sch_issue_mem_en;
                execute_mem_wr <= sch_issue_mem_wr;
                execute_jump <= sch_issue_jump;
                execute_branch <= branch_ctrl;
                execute_write_pc_plus4 <= write_pc_plus4_dec;
                execute_pc_plus4 <= fetch_pc_plus4;
                execute_data_b <= sch_issue_b;
                execute_ctrl <= sch_issue_ctrl;
            end else begin
                execute_valid <= 1'b0;
            end

            mem_enable <= execute_valid && execute_mem_en;
            mem_wren <= execute_valid && execute_mem_en && execute_mem_wr;
            mem_address <= execute_result;
            mem_write_data <= execute_data_b;

            if (execute_valid) begin
                mem_stage_valid <= 1'b1;
                mem_stage_tag <= execute_tag;
                mem_stage_exception <= execute_exception;
                if (execute_mem_en && !execute_mem_wr) begin
                    mem_stage_value <= mem_read_data;
                end else begin
                    mem_stage_value <= execute_result;
                end

                if (execute_jump) begin
                    if (!execute_branch || execute_result[0]) begin
                        jump_valid <= 1'b1;
                        jump_target <= execute_result;
                    end
                end
            end else begin
                mem_stage_valid <= 1'b0;
            end

            if (push_reorder) begin
                mem_stage_valid <= 1'b0;
            end
        end
    end
endmodule
