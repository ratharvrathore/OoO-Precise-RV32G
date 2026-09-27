module cpu (
    input wire clk, reset,

    output wire memEn, memWrEn,
    output wire [31:0] memWrData, memAddr,
    input wire [31:0] dataFromMem,
    input wire memBusy, memDone
);
    localparam SCHEDULER_TAG_BITS = 4;
    localparam REORDER_TAG_BITS   = 3;
    localparam ALU_CONTROL_BITS   = 6;


    //COntrol Wires
    ///////////////
    wire jumpCtrl;
    wire float;
    wire regWrite;

    wire flush;
    wire fetchNext;
    wire reorderNext;
    wire schNext;
    wire aluNext;

    //Fetch
    ///////
    wire [31:0] pcPlus4, newPc, jumpPc;
    wire [31:0] pc, instr;

    reg [31:0] fetchRegPcplus4, fetchRegInstr;
    reg        fetchJumpCtrl, fetchFloat, fetchRegWrite;

    instr_cache instr_cache(
        .clk(clk),
        .instruction_address(pc),
        .instruction(instr)
    );

    assign pcPlus4 = pc + 4;
    // WBJumpCtrl comes from the Write-Back stage (declared below)
    assign newPc   = WBJumpCtrl ? jumpPc : pcPlus4;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pc <= 0;
            fetchRegInstr <= 0;
            fetchRegPcplus4 <= 0;
            fetchJumpCtrl <= 0;
            fetchFloat <= 0;
            fetchRegWrite <= 0;
        end else begin
            if (flush) begin
                fetchRegInstr <= 0;
                fetchRegPcplus4 <= 0;
                fetchJumpCtrl <= 0;
                fetchFloat <= 0;
                fetchRegWrite <= 0;
                pc <= jumpPc;
            end else if (fetchNext) begin
                pc <= newPc;
                fetchRegInstr <= instr;
                fetchRegPcplus4 <= pcPlus4;
                fetchJumpCtrl <= jumpCtrl;
                fetchFloat <= float;
                fetchRegWrite <= regWrite;
            end
        end
    end

    //Docode and Scheduler
    //////////////////////
    wire [31:0] pcPlus4Decode; 
    // Reg-file wires
    wire [4:0] rs1, rs2, rdDecode;
    wire floatDecode, regWriteDecode;
    wire [REORDER_TAG_BITS-1:0] nextROBTag, regTag1, regTag2;
    wire [31:0] dataRs1, dataRs2;
    wire regAvail1, regAvail2;

    // ROB wires
    wire robFull, robEmpty;
    wire [1:0] typeIn;   // 10:Exe 11:load 00:store 01:jump
    wire [4:0] rdIn;
    wire [31:0] robMemAddrIn;
    wire [SCHEDULER_TAG_BITS-1:0] nextSchTag, robSchTagOut1, robSchTagOut2;
    wire [4:0] rdROB;
    wire floatROB, regWriteROB;
    wire [31:0] regDataInROB;
    wire [31:0] dataROB1, dataROB2;
    wire robAvail1, robAvail2;
    wire wBNext;

    // Scheduler wires
    wire schFull, schEmpty;
    wire [31:0] schDataIn1, schDataIn2;
    wire schAvailIn1, schAvailIn2;
    wire schMemEnIn, schMemWrEnIn, schJumpIn;
    wire [ALU_CONTROL_BITS-1:0] schALUControlIn;
    wire [31:0] schDataOut1, schDataOut2;
    wire [SCHEDULER_TAG_BITS-1:0] schTagOut;
    wire [ALU_CONTROL_BITS-1:0]   schALUControlOut;
    wire schMemEnOut, schMemWrEnOut, schJumpOut;

    // Immediate-extended value from the decode stage
    wire [31:0] immExtended;   // produced by an imm-extender sub-module (not shown)

    imm_extend imm_extend (
        .instr (fetchRegInstr),  // instruction sitting in the fetch→decode pipeline reg
        .imm   (immExtended)
    );

    // WB-stage feedback wires (declared here, driven further below)
    wire [31:0] broadcastData;
    wire [SCHEDULER_TAG_BITS-1:0] broadcastTag;
    wire robExceptionIn;
    wire WBJumpCtrl;    // high for one cycle when the ROB commits a jump
    wire [4:0] rdWB;          // destination register being written back
    wire [31:0] regDataIn;     // data written back to the register file

    // Pass-through from fetch regs to decode
    assign floatDecode    = fetchFloat;
    assign regWriteDecode = fetchRegWrite;
    assign pcPlus4Decode  = fetchRegPcplus4;

    wire        jumpCtrl_cu, float_cu, regWrite_cu;
    wire [1:0]  typeIn_cu;
    wire [4:0]  rs1_cu, rs2_cu, rdIn_cu;
    wire        schMemEnIn_cu, schMemWrEnIn_cu, schJumpIn_cu;
    wire [ALU_CONTROL_BITS-1:0] schALUControlIn_cu;
    wire        useImm_cu;
    wire [31:0] robMemAddrIn_cu;
    wire        robExceptionIn_cu;
 
    control_unit #(
        .SCHEDULER_TAG_BITS(SCHEDULER_TAG_BITS),
        .ALU_CONTROL_BITS  (ALU_CONTROL_BITS)
    ) ctrl (
        .instr (fetchRegInstr),
        .rs1 (rs1_cu),
        .rs2 (rs2_cu),
        .rdIn (rdIn_cu),
        .jumpCtrl (jumpCtrl_cu),
        .float (float_cu),
        .regWrite (regWrite_cu),
        .typeIn (typeIn_cu),
        .schMemEnIn (schMemEnIn_cu),
        .schMemWrEnIn (schMemWrEnIn_cu),
        .schJumpIn (schJumpIn_cu),
        .schALUControlIn (schALUControlIn_cu),
        .useImm (useImm_cu),
        .robMemAddrIn (robMemAddrIn_cu),
        .robExceptionIn (robExceptionIn_cu)
    );
 
    // ── Wire CU outputs to the names expected by the rest of the pipeline ──
    assign jumpCtrl = jumpCtrl_cu;
    assign float = float_cu;
    assign regWrite = regWrite_cu;
 
    assign typeIn = typeIn_cu;
    assign rdIn = rdIn_cu;
    assign rs1 = rs1_cu;
    assign rs2 = rs2_cu;
 
    assign schMemEnIn = schMemEnIn_cu;
    assign schMemWrEnIn = schMemWrEnIn_cu;
    assign rdDecode = rdIn;    // the destination register seen by the reg-file 
    assign schALUControlIn = schALUControlIn_cu;
    assign useImm = useImm_cu;
    assign robMemAddrIn = robMemAddrIn_cu;
    assign robExceptionIn = robExceptionIn_cu;

    reg_file reg_file(
        .clk(clk), .reset(reset),
        .rs1(rs1), .rs2(rs2), .rdDecode(rdDecode),
        .floatDecode(floatDecode), .fetchNext(fetchNext), .regWriteDecode(regWriteDecode),
        .nextTag(nextROBTag),
        .dataRs1(dataRs1), .dataRs2(dataRs2),
        .tag1(regTag1), .tag2(regTag2),
        .available1(regAvail1), .available2(regAvail2),
        .rdROB(rdROB),
        .floatROB(floatROB), .wBNext(wBNext), .regWriteROB(regWriteROB),
        .dataInROB(regDataIn)
    );

    reorder_buffer reorder_buffer(
        .clk(clk), .reset(reset),
        .full(robFull), .empty(robEmpty),
        .typeIn(typeIn),
        .rdIn(rdIn),
        .memAddrIn(robMemAddrIn),
        .dataIn(broadcastData),
        .pcPlus4In(pcPlus4Decode),
        .exceptionFlagIn(robExceptionIn),
        .nextSchTag(nextSchTag),
        .tagA(regTag1), .tagB(regTag2),
        .push_fetch(fetchNext), .push_reorder(reorderNext),
        .broadcastSchTag(broadcastTag),
        .dataOutReg(regDataIn),
        .rdOut(rdWB),
        .regWrEn(regWriteROB), .wBNext(wBNext),
        .broadcastNextTag(nextROBTag),
        .dataOutA(dataROB1), .dataOutB(dataROB2),
        .schTagA(robSchTagOut1), .schTagB(robSchTagOut2),
        .validA(robAvail1), .validB(robAvail2)
    );

    scheduler scheduler(
        .clk(clk), .reset(reset),
        .full(schFull), .empty(schEmpty),
        .schDataIn1(schDataIn1), .schDataIn2(schDataIn2),
        .tagAIn(robSchTagOut1), .tagBIn(robSchTagOut2),
        .availableA(schAvailIn1), .availableB(schAvailIn2),
        .memEnIn(schMemEnIn), .memWrEnIn(schMemWrEnIn), .jumpIn(schJumpIn),
        .aluControlIn(schALUControlIn),
        .push_fetch(fetchNext), .push_schdule(schNext), .push_reorder(reorderNext),
        .broadcastData(broadcastData), .broadcastTag(broadcastTag),
        .dataOutA(schDataOut1), .dataOutB(schDataOut2),
        .tagOut(schTagOut), .aluControlOut(schALUControlOut),
        .memEnOut(schMemEnOut), .memWrEnOut(schMemWrEnOut), .jumpOut(schJumpOut),
        .nextSchTag(nextSchTag)
    );

    wire useImm;  // driven by decode control unit

    assign schDataIn1 = robAvail1 ? dataROB1 : dataRs1; 
    assign schDataIn2 = useImm ? immExtended : (robAvail2 ? dataROB2 : dataRs2); 
    assign schAvailIn1 = robAvail1 | regAvail1; 
    assign schAvailIn2 = useImm | robAvail2 | regAvail2;

    // ── Control signals into the scheduler ────────────────────
    // (These are driven by the decode / control-unit logic)
    assign schJumpIn = fetchJumpCtrl; // the decoded jump flag

    //Execute
    //////////
    wire [31:0] aluData1, aluData2;
    wire [ALU_CONTROL_BITS-1:0] aluControl;
    wire aluBusy, aluDone;
    wire [31:0] aluOut;
    wire aluException;

    assign aluData1  = schDataOut1;
    assign aluData2  = schDataOut2;
    assign aluControl = schALUControlOut;

    ALU ALU(
        .clk(clk), .reset(reset),
        .dataA(aluData1), .dataB(aluData2),
        .ALUControl(aluControl),
        .pushNewALU(aluNext),
        .busy(aluBusy), .done(aluDone),
        .dataOut(aluOut),
        .exceptionRaised(aluException)
    );

    reg [31:0] exeRegResult;
    reg [SCHEDULER_TAG_BITS-1:0] exeRegTag;
    reg exeRegMemEn, exeRegMemWrEn, exeRegJump;
    reg exeRegException;
    reg [31:0] exeRegDataB;   // store value (rs2) for SW

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            exeRegResult <= 0;
            exeRegTag <= 0;
            exeRegMemEn <= 0;
            exeRegMemWrEn <= 0;
            exeRegJump <= 0;
            exeRegException <= 0;
            exeRegDataB <= 0;
        end else if (aluDone) begin
            // aluDone is high for exactly one cycle (per spec)
            exeRegResult <= aluOut;
            exeRegTag <= schTagOut;
            exeRegMemEn <= schMemEnOut;
            exeRegMemWrEn <= schMemWrEnOut;
            exeRegJump <= schJumpOut;
            exeRegException <= aluException;
            exeRegDataB <= schDataOut2;   // rs2 = store data for SW
        end
    end

    //Memory
    /////////
    assign memEn = exeRegMemEn;
    assign memWrEn = exeRegMemWrEn;
    assign memAddr = exeRegResult;    // ALU computed the effective address
    assign memWrData = exeRegDataB;     // store value comes from rs2

    reg [31:0] memRegData;    // data to broadcast
    reg [SCHEDULER_TAG_BITS-1:0] memRegTag;
    reg memRegJump;
    reg memRegException;
    reg memRegValid;   // entry is ready to commit

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            memRegData <= 0;
            memRegTag <= 0;
            memRegJump <= 0;
            memRegException <= 0;
            memRegValid <= 0;
        end else begin
            if (exeRegMemEn && !exeRegMemWrEn) begin
                if (memDone) begin
                    memRegData <= dataFromMem;
                    memRegTag <= exeRegTag;
                    memRegJump <= exeRegJump;
                    memRegException <= exeRegException;
                    memRegValid <= 1'b1;
                end else begin
                    memRegValid <= 1'b0;
                end
            end else begin
                memRegData <= exeRegResult;
                memRegTag <= exeRegTag;
                memRegJump <= exeRegJump;
                memRegException <= exeRegException;
                memRegValid     <= !exeRegMemEn || memDone;
            end
        end
    end

    //Reorder
    /////////

    assign reorderNext = wbRegValid;      // ROB commits when WB stage is valid
    assign broadcastData = wbRegData;       // data broadcast comes from WB reg
    assign broadcastTag = wbRegTag;        // tag broadcast comes from WB reg
    assign robExceptionIn = wbRegException; // exception flag from WB reg

    reg [31:0] wbRegData;
    reg [SCHEDULER_TAG_BITS-1:0] wbRegTag;
    reg wbRegJump;
    reg wbRegException;
    reg wbRegValid;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            wbRegData <= 0;
            wbRegTag <= 0;
            wbRegJump <= 0;
            wbRegException <= 0;
            wbRegValid <= 0;
        end else begin
            if (memRegValid) begin
                wbRegData <= memRegData;
                wbRegTag <= memRegTag;
                wbRegJump <= memRegJump;
                wbRegException <= memRegException;
                wbRegValid <= 1'b1;
            end else begin
                wbRegValid <= 1'b0;
            end
        end
    end

    //Write back

    assign jumpPc = wbRegData;                   // jump target latched in WB reg
    assign WBJumpCtrl = wbRegJump && wbRegValid;     // one-cycle pulse on commit
    assign flush = WBJumpCtrl;                  // flush fetch/decode on mis-predict

endmodule
