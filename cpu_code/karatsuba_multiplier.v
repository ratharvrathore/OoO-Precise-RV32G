module karatsuba_multiplier(
    input wire clk, reset,
    input wire [31:0] dataA, dataB,
    input wire pushNewMult,
    input wire signed_mode,

    output reg [63:0] dataOut,
    output reg busy, done
);
    reg [31:0] dataASave, dataBSave;
    reg [16:0] karatA, karatB;          // 17-bit: 16 data + 1 for sign or carry
    wire [33:0] multRes;                 // 17*17 = 34-bit
    reg [33:0] multRes1, multRes2;
    reg [2:0] state;

    assign multRes = karatA * karatB;

    localparam IDLE   = 0;
    localparam STEP_1 = 1;
    localparam STEP_2 = 2;
    localparam STEP_3 = 3;
    localparam STEP_4 = 4;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy  <= 0;
            done  <= 0;
        end else begin
            case (state)
                IDLE: begin
                    done <= 0;
                    if (pushNewMult) begin
                        dataASave <= dataA;
                        dataBSave <= dataB;
                        state     <= STEP_1;
                        busy      <= 1;
                    end
                end
                STEP_1: begin
                    karatA <= signed_mode ? {dataASave[15], dataASave[15:0]}
                                          : {1'b0, dataASave[15:0]};
                    karatB <= signed_mode ? {dataBSave[15], dataBSave[15:0]}
                                          : {1'b0, dataBSave[15:0]};
                    state  <= STEP_2;
                end
                STEP_2: begin
                    multRes1 <= multRes;
                    karatA   <= signed_mode ? {dataASave[31], dataASave[31:16]}
                                           : {1'b0, dataASave[31:16]};
                    karatB   <= signed_mode ? {dataBSave[31], dataBSave[31:16]}
                                           : {1'b0, dataBSave[31:16]};
                    state    <= STEP_3;
                end
                STEP_3: begin
                    // multRes now holds hi*hi
                    multRes2 <= multRes;
                    // half-sum: sign-extended hi + sign-extended lo
                    // no extra sign bit needed here, 17-bit already holds the carry
                    karatA   <= (signed_mode ? {dataASave[31], dataASave[31:16]}
                                             : {1'b0, dataASave[31:16]})
                              + (signed_mode ? {dataASave[15], dataASave[15:0]}
                                             : {1'b0, dataASave[15:0]});
                    karatB   <= (signed_mode ? {dataBSave[31], dataBSave[31:16]}
                                             : {1'b0, dataBSave[31:16]})
                              + (signed_mode ? {dataBSave[15], dataBSave[15:0]}
                                             : {1'b0, dataBSave[15:0]});
                    state    <= STEP_4;
                end
                STEP_4: begin
                    // multRes now holds mid*mid
                    // sign-extend each partial product to 64 bits before shifting
                    dataOut <= {{30{multRes1[33]}}, multRes1}
                             + ({{30{multRes2[33]}}, multRes2} << 32)
                             + ((  {{30{multRes[33]}},  multRes}
                                 - {{30{multRes1[33]}}, multRes1}
                                 - {{30{multRes2[33]}}, multRes2}) << 16);
                    done  <= 1;
                    busy  <= 0;
                    state <= IDLE;
                end
                default: ;
            endcase
        end
    end
endmodule