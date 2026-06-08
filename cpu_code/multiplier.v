module multiplier #(
    parameter SPLIT_COUNT = 8
) (
    input wire clk, reset,
    input wire [31:0] dataA, dataB,
    input wire pushNewMult,
    input wire signed_mode,

    output reg [63:0] dataOut,
    output reg busy, done
);
    localparam SPLIT_WIDTH = 32/SPLIT_COUNT;
    reg [63:0] dataStore, dataASave, dataACompute, dataBSave;
    reg [63:0] dataInter;
    reg [($clog2(SPLIT_COUNT)):0] countState;
    reg [SPLIT_WIDTH-1:0] dataCompute;
    reg valid;
    wire [SPLIT_WIDTH-1:0] dataSplitting;

    // now iterating over 64 bits of the saved (possibly sign-extended) B
    assign dataSplitting = dataBSave[(countState * SPLIT_WIDTH) +: SPLIT_WIDTH];

    integer i;
    always @(*) begin
        dataInter = 0;
        for (i = 0; i < SPLIT_WIDTH; i = i+1) begin
            dataInter = dataInter + ((dataACompute & {64{dataCompute[i]}}) << i);
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            valid      <= 0;
            busy       <= 0;
            done       <= 0;
            countState <= 0;
            dataStore  <= 0;
            dataOut    <= 0;
        end else begin
            done <= 0;
            if (pushNewMult && !busy) begin
                // sign-extend if signed_mode, else zero-extend
                dataASave <= signed_mode ? {{32{dataA[31]}}, dataA} : {32'd0, dataA};
                dataBSave <= signed_mode ? {{32{dataB[31]}}, dataB} : {32'd0, dataB};
                busy       <= 1;
                valid      <= 0;
                countState <= 0;
            end
            if (busy) begin
                dataCompute  <= dataSplitting;
                dataACompute <= dataASave;
                if (valid) begin
                    dataStore <= dataStore + dataInter;
                end else begin
                    dataStore <= dataInter;
                    valid     <= 1;
                end
                if (countState == SPLIT_COUNT - 1) begin
                    busy       <= 0;
                    valid      <= 0;
                    done       <= 1;
                    dataOut    <= dataStore + dataInter;
                    countState <= 0;
                end else begin
                    countState <= countState + 1;
                end
            end
        end
    end
endmodule