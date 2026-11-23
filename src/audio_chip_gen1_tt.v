`timescale 1ns/1ps
`default_nettype none
// ---------------------------------------------------------------
// Audio chip, memory section: 15 cells (as drawn).
// SEPARATE CHIP: nothing here depends on the CPU files.
//
// Each cell is exactly what is drawn:
//   NOT gate on clk -> FF1 (so FF1 triggers on the falling edge)
//   FF1.D = mux output
//   FF2.clk = clk (rising edge), FF2.D = FF1.Q, cell output = FF2.Q
//   4:1 mux: input 0 = FF2.Q, inputs 1..3 = whatever the schematic
//            connects there (left as ports: in1, in2, in3)
//
// No reset and no extra logic were added. The only addition is the
// `initial` start state of 0, which simulator.io also powers up with;
// without it a Verilog simulator starts every flip-flop at X and the
// hold loop would never leave X.
// ---------------------------------------------------------------
module mem_bit (
    input  wire       clk,
    input  wire [1:0] sel,
    input  wire       in1,
    input  wire       in2,
    input  wire       in3,
    output wire       q
);
    reg ff1;
    reg ff2;
    reg mux_out;

    always @* begin
        case (sel)
            2'b00:   mux_out = ff2;
            2'b01:   mux_out = in1;
            2'b10:   mux_out = in2;
            2'b11:   mux_out = in3;
            default: mux_out = ff2;
        endcase
    end

    always @(negedge clk) ff1 <= mux_out;
    always @(posedge clk) ff2 <= ff1;

    assign q = ff2;

    initial begin
        ff1 = 1'b0;
        ff2 = 1'b0;
    end
endmodule

module audio_mem #(
    parameter WIDTH = 15          // 15 cells as drawn
) (
    input  wire             clk,
    input  wire [1:0]       sel,  // shared by every mux (as it appears drawn)
    input  wire [WIDTH-1:0] in1,
    input  wire [WIDTH-1:0] in2,
    input  wire [WIDTH-1:0] in3,
    output wire [WIDTH-1:0] q
);
    genvar i;
    generate
        for (i = 0; i < WIDTH; i = i + 1) begin : bitcell
            mem_bit b (
                .clk (clk),
                .sel (sel),
                .in1 (in1[i]),
                .in2 (in2[i]),
                .in3 (in3[i]),
                .q   (q[i])
            );
        end
    endgenerate
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Audio chip: full-adder chain, expanded from the 3 drawn to 15 bits.
// Same ripple-carry structure as the staircase in the schematic:
// each full adder's carry-out feeds the next one's carry-in.
// Which signals feed a[], b[] and cin is left as ports until the
// connections can be read from the schematic.
// ---------------------------------------------------------------
module audio_fa (
    input  wire a,
    input  wire b,
    input  wire cin,
    output wire sum,
    output wire cout
);
    assign sum  = a ^ b ^ cin;
    assign cout = (a & b) | (cin & (a ^ b));
endmodule

module audio_adder #(
    parameter WIDTH = 15
) (
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire             cin,
    output wire [WIDTH-1:0] sum,
    output wire             cout
);
    wire [WIDTH:0] c;
    assign c[0] = cin;
    assign cout = c[WIDTH];

    genvar i;
    generate
        for (i = 0; i < WIDTH; i = i + 1) begin : fa
            audio_fa f (
                .a    (a[i]),
                .b    (b[i]),
                .cin  (c[i]),
                .sum  (sum[i]),
                .cout (c[i+1])
            );
        end
    endgenerate
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Audio chip core = memory cells + adder, wired as an ACCUMULATOR.
// Needs audio_mem.v and audio_adder.v.
//
// INFERRED wiring (the screenshot's wires are not legible, so this is
// the connection that fits the parts: a memory plus an adder):
//   adder a    = memory outputs (q)
//   adder b    = external operand `b`
//   adder cin  = constant 0
//   mux input 1 = constant 0     (clear)
//   mux input 2 = adder sum      (accumulate: q <= q + b)
//   mux input 3 = q              (hold)
//   mux input 0 = q              (hold, inside each cell)
//
// sel: 00 hold, 01 clear, 10 add b into memory, 11 hold
// Hold sel=10 for ONE clock per add.
// ---------------------------------------------------------------
module audio_core #(
    parameter WIDTH = 15
) (
    input  wire             clk,
    input  wire [1:0]       sel,
    input  wire [WIDTH-1:0] b,
    output wire [WIDTH-1:0] q,
    output wire             cout
);
    wire [WIDTH-1:0] sum;

    audio_adder #(.WIDTH(WIDTH)) add (
        .a    (q),
        .b    (b),
        .cin  (1'b0),
        .sum  (sum),
        .cout (cout)
    );

    audio_mem #(.WIDTH(WIDTH)) mem (
        .clk (clk),
        .sel (sel),
        .in1 ({WIDTH{1'b0}}),
        .in2 (sum),
        .in3 (q),
        .q   (q)
    );
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Sine, 16-bit signed, from a 257-entry quarter-wave table with
// linear interpolation and rounding (worst error about 1.7 LSB, about
// 93 dB signal-to-error, close to the 98 dB limit of 16 bits).
// Phase is a full 32-bit phase word.
// ---------------------------------------------------------------
module sine_lut (
    input  wire [31:0]        phase,
    output wire signed [15:0] sine
);
    wire [1:0]  quad = phase[31:30];
    wire [15:0] pos  = phase[29:14];
    // odd quadrants run the table backwards
    wire [16:0] p17  = quad[0] ? (17'd65536 - {1'b0, pos}) : {1'b0, pos};
    wire [8:0]  i    = p17[16:8];                 // 0..256
    wire [7:0]  f    = p17[7:0];
    wire [8:0]  i1   = (i == 9'd256) ? 9'd256 : (i + 9'd1);

    function [14:0] rom;
        input [8:0] idx;
        begin
            case (idx)
            9'd0: rom = 15'd0; 9'd1: rom = 15'd201; 9'd2: rom = 15'd402; 9'd3: rom = 15'd603; 9'd4: rom = 15'd804; 9'd5: rom = 15'd1005;
            9'd6: rom = 15'd1206; 9'd7: rom = 15'd1407; 9'd8: rom = 15'd1608; 9'd9: rom = 15'd1809; 9'd10: rom = 15'd2009; 9'd11: rom = 15'd2210;
            9'd12: rom = 15'd2410; 9'd13: rom = 15'd2611; 9'd14: rom = 15'd2811; 9'd15: rom = 15'd3012; 9'd16: rom = 15'd3212; 9'd17: rom = 15'd3412;
            9'd18: rom = 15'd3612; 9'd19: rom = 15'd3811; 9'd20: rom = 15'd4011; 9'd21: rom = 15'd4210; 9'd22: rom = 15'd4410; 9'd23: rom = 15'd4609;
            9'd24: rom = 15'd4808; 9'd25: rom = 15'd5007; 9'd26: rom = 15'd5205; 9'd27: rom = 15'd5404; 9'd28: rom = 15'd5602; 9'd29: rom = 15'd5800;
            9'd30: rom = 15'd5998; 9'd31: rom = 15'd6195; 9'd32: rom = 15'd6393; 9'd33: rom = 15'd6590; 9'd34: rom = 15'd6786; 9'd35: rom = 15'd6983;
            9'd36: rom = 15'd7179; 9'd37: rom = 15'd7375; 9'd38: rom = 15'd7571; 9'd39: rom = 15'd7767; 9'd40: rom = 15'd7962; 9'd41: rom = 15'd8157;
            9'd42: rom = 15'd8351; 9'd43: rom = 15'd8545; 9'd44: rom = 15'd8739; 9'd45: rom = 15'd8933; 9'd46: rom = 15'd9126; 9'd47: rom = 15'd9319;
            9'd48: rom = 15'd9512; 9'd49: rom = 15'd9704; 9'd50: rom = 15'd9896; 9'd51: rom = 15'd10087; 9'd52: rom = 15'd10278; 9'd53: rom = 15'd10469;
            9'd54: rom = 15'd10659; 9'd55: rom = 15'd10849; 9'd56: rom = 15'd11039; 9'd57: rom = 15'd11228; 9'd58: rom = 15'd11417; 9'd59: rom = 15'd11605;
            9'd60: rom = 15'd11793; 9'd61: rom = 15'd11980; 9'd62: rom = 15'd12167; 9'd63: rom = 15'd12353; 9'd64: rom = 15'd12539; 9'd65: rom = 15'd12725;
            9'd66: rom = 15'd12910; 9'd67: rom = 15'd13094; 9'd68: rom = 15'd13279; 9'd69: rom = 15'd13462; 9'd70: rom = 15'd13645; 9'd71: rom = 15'd13828;
            9'd72: rom = 15'd14010; 9'd73: rom = 15'd14191; 9'd74: rom = 15'd14372; 9'd75: rom = 15'd14553; 9'd76: rom = 15'd14732; 9'd77: rom = 15'd14912;
            9'd78: rom = 15'd15090; 9'd79: rom = 15'd15269; 9'd80: rom = 15'd15446; 9'd81: rom = 15'd15623; 9'd82: rom = 15'd15800; 9'd83: rom = 15'd15976;
            9'd84: rom = 15'd16151; 9'd85: rom = 15'd16325; 9'd86: rom = 15'd16499; 9'd87: rom = 15'd16673; 9'd88: rom = 15'd16846; 9'd89: rom = 15'd17018;
            9'd90: rom = 15'd17189; 9'd91: rom = 15'd17360; 9'd92: rom = 15'd17530; 9'd93: rom = 15'd17700; 9'd94: rom = 15'd17869; 9'd95: rom = 15'd18037;
            9'd96: rom = 15'd18204; 9'd97: rom = 15'd18371; 9'd98: rom = 15'd18537; 9'd99: rom = 15'd18703; 9'd100: rom = 15'd18868; 9'd101: rom = 15'd19032;
            9'd102: rom = 15'd19195; 9'd103: rom = 15'd19357; 9'd104: rom = 15'd19519; 9'd105: rom = 15'd19680; 9'd106: rom = 15'd19841; 9'd107: rom = 15'd20000;
            9'd108: rom = 15'd20159; 9'd109: rom = 15'd20317; 9'd110: rom = 15'd20475; 9'd111: rom = 15'd20631; 9'd112: rom = 15'd20787; 9'd113: rom = 15'd20942;
            9'd114: rom = 15'd21096; 9'd115: rom = 15'd21250; 9'd116: rom = 15'd21403; 9'd117: rom = 15'd21554; 9'd118: rom = 15'd21705; 9'd119: rom = 15'd21856;
            9'd120: rom = 15'd22005; 9'd121: rom = 15'd22154; 9'd122: rom = 15'd22301; 9'd123: rom = 15'd22448; 9'd124: rom = 15'd22594; 9'd125: rom = 15'd22739;
            9'd126: rom = 15'd22884; 9'd127: rom = 15'd23027; 9'd128: rom = 15'd23170; 9'd129: rom = 15'd23311; 9'd130: rom = 15'd23452; 9'd131: rom = 15'd23592;
            9'd132: rom = 15'd23731; 9'd133: rom = 15'd23870; 9'd134: rom = 15'd24007; 9'd135: rom = 15'd24143; 9'd136: rom = 15'd24279; 9'd137: rom = 15'd24413;
            9'd138: rom = 15'd24547; 9'd139: rom = 15'd24680; 9'd140: rom = 15'd24811; 9'd141: rom = 15'd24942; 9'd142: rom = 15'd25072; 9'd143: rom = 15'd25201;
            9'd144: rom = 15'd25329; 9'd145: rom = 15'd25456; 9'd146: rom = 15'd25582; 9'd147: rom = 15'd25708; 9'd148: rom = 15'd25832; 9'd149: rom = 15'd25955;
            9'd150: rom = 15'd26077; 9'd151: rom = 15'd26198; 9'd152: rom = 15'd26319; 9'd153: rom = 15'd26438; 9'd154: rom = 15'd26556; 9'd155: rom = 15'd26674;
            9'd156: rom = 15'd26790; 9'd157: rom = 15'd26905; 9'd158: rom = 15'd27019; 9'd159: rom = 15'd27133; 9'd160: rom = 15'd27245; 9'd161: rom = 15'd27356;
            9'd162: rom = 15'd27466; 9'd163: rom = 15'd27575; 9'd164: rom = 15'd27683; 9'd165: rom = 15'd27790; 9'd166: rom = 15'd27896; 9'd167: rom = 15'd28001;
            9'd168: rom = 15'd28105; 9'd169: rom = 15'd28208; 9'd170: rom = 15'd28310; 9'd171: rom = 15'd28411; 9'd172: rom = 15'd28510; 9'd173: rom = 15'd28609;
            9'd174: rom = 15'd28706; 9'd175: rom = 15'd28803; 9'd176: rom = 15'd28898; 9'd177: rom = 15'd28992; 9'd178: rom = 15'd29085; 9'd179: rom = 15'd29177;
            9'd180: rom = 15'd29268; 9'd181: rom = 15'd29358; 9'd182: rom = 15'd29447; 9'd183: rom = 15'd29534; 9'd184: rom = 15'd29621; 9'd185: rom = 15'd29706;
            9'd186: rom = 15'd29791; 9'd187: rom = 15'd29874; 9'd188: rom = 15'd29956; 9'd189: rom = 15'd30037; 9'd190: rom = 15'd30117; 9'd191: rom = 15'd30195;
            9'd192: rom = 15'd30273; 9'd193: rom = 15'd30349; 9'd194: rom = 15'd30424; 9'd195: rom = 15'd30498; 9'd196: rom = 15'd30571; 9'd197: rom = 15'd30643;
            9'd198: rom = 15'd30714; 9'd199: rom = 15'd30783; 9'd200: rom = 15'd30852; 9'd201: rom = 15'd30919; 9'd202: rom = 15'd30985; 9'd203: rom = 15'd31050;
            9'd204: rom = 15'd31113; 9'd205: rom = 15'd31176; 9'd206: rom = 15'd31237; 9'd207: rom = 15'd31297; 9'd208: rom = 15'd31356; 9'd209: rom = 15'd31414;
            9'd210: rom = 15'd31470; 9'd211: rom = 15'd31526; 9'd212: rom = 15'd31580; 9'd213: rom = 15'd31633; 9'd214: rom = 15'd31685; 9'd215: rom = 15'd31736;
            9'd216: rom = 15'd31785; 9'd217: rom = 15'd31833; 9'd218: rom = 15'd31880; 9'd219: rom = 15'd31926; 9'd220: rom = 15'd31971; 9'd221: rom = 15'd32014;
            9'd222: rom = 15'd32057; 9'd223: rom = 15'd32098; 9'd224: rom = 15'd32137; 9'd225: rom = 15'd32176; 9'd226: rom = 15'd32213; 9'd227: rom = 15'd32250;
            9'd228: rom = 15'd32285; 9'd229: rom = 15'd32318; 9'd230: rom = 15'd32351; 9'd231: rom = 15'd32382; 9'd232: rom = 15'd32412; 9'd233: rom = 15'd32441;
            9'd234: rom = 15'd32469; 9'd235: rom = 15'd32495; 9'd236: rom = 15'd32521; 9'd237: rom = 15'd32545; 9'd238: rom = 15'd32567; 9'd239: rom = 15'd32589;
            9'd240: rom = 15'd32609; 9'd241: rom = 15'd32628; 9'd242: rom = 15'd32646; 9'd243: rom = 15'd32663; 9'd244: rom = 15'd32678; 9'd245: rom = 15'd32692;
            9'd246: rom = 15'd32705; 9'd247: rom = 15'd32717; 9'd248: rom = 15'd32728; 9'd249: rom = 15'd32737; 9'd250: rom = 15'd32745; 9'd251: rom = 15'd32752;
            9'd252: rom = 15'd32757; 9'd253: rom = 15'd32761; 9'd254: rom = 15'd32765; 9'd255: rom = 15'd32766; 9'd256: rom = 15'd32767;
            default: rom = 15'd32767;
            endcase
        end
    endfunction

    wire signed [17:0] a_s = {3'b000, rom(i)};
    wire signed [17:0] b_s = {3'b000, rom(i1)};
    wire signed [8:0]  f_s = {1'b0, f};
    wire signed [26:0] delta  = (b_s - a_s) * f_s;
    wire signed [26:0] v_full = a_s + ((delta + 27'sd128) >>> 8);   // rounded
    wire signed [15:0] mag    = v_full[15:0];

    assign sine = quad[1] ? -mag : mag;
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Volume picker curve: 8-bit setting -> 16-bit linear gain.
// 0 = mute, 1..255 = 0.25 dB per step, 255 = full scale (about
// 64 dB of range), so equal steps sound like equal loudness steps.
// ---------------------------------------------------------------
module vol_lut (
    input  wire [7:0]  sel,
    output wire [15:0] gain
);
    function [15:0] lut;
        input [7:0] s;
        begin
        case (s)
            8'd0: lut = 16'd0; 8'd1: lut = 16'd44; 8'd2: lut = 16'd45; 8'd3: lut = 16'd46; 8'd4: lut = 16'd48; 8'd5: lut = 16'd49;
            8'd6: lut = 16'd51; 8'd7: lut = 16'd52; 8'd8: lut = 16'd54; 8'd9: lut = 16'd55; 8'd10: lut = 16'd57; 8'd11: lut = 16'd58;
            8'd12: lut = 16'd60; 8'd13: lut = 16'd62; 8'd14: lut = 16'd64; 8'd15: lut = 16'd66; 8'd16: lut = 16'd67; 8'd17: lut = 16'd69;
            8'd18: lut = 16'd71; 8'd19: lut = 16'd74; 8'd20: lut = 16'd76; 8'd21: lut = 16'd78; 8'd22: lut = 16'd80; 8'd23: lut = 16'd83;
            8'd24: lut = 16'd85; 8'd25: lut = 16'd87; 8'd26: lut = 16'd90; 8'd27: lut = 16'd93; 8'd28: lut = 16'd95; 8'd29: lut = 16'd98;
            8'd30: lut = 16'd101; 8'd31: lut = 16'd104; 8'd32: lut = 16'd107; 8'd33: lut = 16'd110; 8'd34: lut = 16'd113; 8'd35: lut = 16'd117;
            8'd36: lut = 16'd120; 8'd37: lut = 16'd123; 8'd38: lut = 16'd127; 8'd39: lut = 16'd131; 8'd40: lut = 16'd135; 8'd41: lut = 16'd139;
            8'd42: lut = 16'd143; 8'd43: lut = 16'd147; 8'd44: lut = 16'd151; 8'd45: lut = 16'd155; 8'd46: lut = 16'd160; 8'd47: lut = 16'd165;
            8'd48: lut = 16'd169; 8'd49: lut = 16'd174; 8'd50: lut = 16'd179; 8'd51: lut = 16'd185; 8'd52: lut = 16'd190; 8'd53: lut = 16'd196;
            8'd54: lut = 16'd201; 8'd55: lut = 16'd207; 8'd56: lut = 16'd213; 8'd57: lut = 16'd220; 8'd58: lut = 16'd226; 8'd59: lut = 16'd233;
            8'd60: lut = 16'd239; 8'd61: lut = 16'd246; 8'd62: lut = 16'd253; 8'd63: lut = 16'd261; 8'd64: lut = 16'd269; 8'd65: lut = 16'd276;
            8'd66: lut = 16'd284; 8'd67: lut = 16'd293; 8'd68: lut = 16'd301; 8'd69: lut = 16'd310; 8'd70: lut = 16'd319; 8'd71: lut = 16'd328;
            8'd72: lut = 16'd338; 8'd73: lut = 16'd348; 8'd74: lut = 16'd358; 8'd75: lut = 16'd369; 8'd76: lut = 16'd379; 8'd77: lut = 16'd390;
            8'd78: lut = 16'd402; 8'd79: lut = 16'd413; 8'd80: lut = 16'd426; 8'd81: lut = 16'd438; 8'd82: lut = 16'd451; 8'd83: lut = 16'd464;
            8'd84: lut = 16'd477; 8'd85: lut = 16'd491; 8'd86: lut = 16'd506; 8'd87: lut = 16'd521; 8'd88: lut = 16'd536; 8'd89: lut = 16'd551;
            8'd90: lut = 16'd568; 8'd91: lut = 16'd584; 8'd92: lut = 16'd601; 8'd93: lut = 16'd619; 8'd94: lut = 16'd637; 8'd95: lut = 16'd655;
            8'd96: lut = 16'd674; 8'd97: lut = 16'd694; 8'd98: lut = 16'd714; 8'd99: lut = 16'd735; 8'd100: lut = 16'd757; 8'd101: lut = 16'd779;
            8'd102: lut = 16'd802; 8'd103: lut = 16'd825; 8'd104: lut = 16'd849; 8'd105: lut = 16'd874; 8'd106: lut = 16'd899; 8'd107: lut = 16'd926;
            8'd108: lut = 16'd953; 8'd109: lut = 16'd981; 8'd110: lut = 16'd1009; 8'd111: lut = 16'd1039; 8'd112: lut = 16'd1069; 8'd113: lut = 16'd1100;
            8'd114: lut = 16'd1132; 8'd115: lut = 16'd1165; 8'd116: lut = 16'd1199; 8'd117: lut = 16'd1234; 8'd118: lut = 16'd1270; 8'd119: lut = 16'd1308;
            8'd120: lut = 16'd1346; 8'd121: lut = 16'd1385; 8'd122: lut = 16'd1426; 8'd123: lut = 16'd1467; 8'd124: lut = 16'd1510; 8'd125: lut = 16'd1554;
            8'd126: lut = 16'd1599; 8'd127: lut = 16'd1646; 8'd128: lut = 16'd1694; 8'd129: lut = 16'd1744; 8'd130: lut = 16'd1795; 8'd131: lut = 16'd1847;
            8'd132: lut = 16'd1901; 8'd133: lut = 16'd1956; 8'd134: lut = 16'd2014; 8'd135: lut = 16'd2072; 8'd136: lut = 16'd2133; 8'd137: lut = 16'd2195;
            8'd138: lut = 16'd2259; 8'd139: lut = 16'd2325; 8'd140: lut = 16'd2393; 8'd141: lut = 16'd2463; 8'd142: lut = 16'd2535; 8'd143: lut = 16'd2609;
            8'd144: lut = 16'd2685; 8'd145: lut = 16'd2764; 8'd146: lut = 16'd2844; 8'd147: lut = 16'd2927; 8'd148: lut = 16'd3013; 8'd149: lut = 16'd3101;
            8'd150: lut = 16'd3191; 8'd151: lut = 16'd3285; 8'd152: lut = 16'd3380; 8'd153: lut = 16'd3479; 8'd154: lut = 16'd3581; 8'd155: lut = 16'd3685;
            8'd156: lut = 16'd3793; 8'd157: lut = 16'd3904; 8'd158: lut = 16'd4018; 8'd159: lut = 16'd4135; 8'd160: lut = 16'd4256; 8'd161: lut = 16'd4380;
            8'd162: lut = 16'd4508; 8'd163: lut = 16'd4640; 8'd164: lut = 16'd4775; 8'd165: lut = 16'd4914; 8'd166: lut = 16'd5058; 8'd167: lut = 16'd5206;
            8'd168: lut = 16'd5358; 8'd169: lut = 16'd5514; 8'd170: lut = 16'd5675; 8'd171: lut = 16'd5841; 8'd172: lut = 16'd6011; 8'd173: lut = 16'd6187;
            8'd174: lut = 16'd6368; 8'd175: lut = 16'd6554; 8'd176: lut = 16'd6745; 8'd177: lut = 16'd6942; 8'd178: lut = 16'd7145; 8'd179: lut = 16'd7353;
            8'd180: lut = 16'd7568; 8'd181: lut = 16'd7789; 8'd182: lut = 16'd8016; 8'd183: lut = 16'd8250; 8'd184: lut = 16'd8491; 8'd185: lut = 16'd8739;
            8'd186: lut = 16'd8994; 8'd187: lut = 16'd9257; 8'd188: lut = 16'd9527; 8'd189: lut = 16'd9806; 8'd190: lut = 16'd10092; 8'd191: lut = 16'd10387;
            8'd192: lut = 16'd10690; 8'd193: lut = 16'd11002; 8'd194: lut = 16'd11323; 8'd195: lut = 16'd11654; 8'd196: lut = 16'd11994; 8'd197: lut = 16'd12344;
            8'd198: lut = 16'd12705; 8'd199: lut = 16'd13076; 8'd200: lut = 16'd13458; 8'd201: lut = 16'd13851; 8'd202: lut = 16'd14255; 8'd203: lut = 16'd14671;
            8'd204: lut = 16'd15100; 8'd205: lut = 16'd15541; 8'd206: lut = 16'd15995; 8'd207: lut = 16'd16462; 8'd208: lut = 16'd16942; 8'd209: lut = 16'd17437;
            8'd210: lut = 16'd17946; 8'd211: lut = 16'd18470; 8'd212: lut = 16'd19010; 8'd213: lut = 16'd19565; 8'd214: lut = 16'd20136; 8'd215: lut = 16'd20724;
            8'd216: lut = 16'd21329; 8'd217: lut = 16'd21952; 8'd218: lut = 16'd22593; 8'd219: lut = 16'd23253; 8'd220: lut = 16'd23932; 8'd221: lut = 16'd24631;
            8'd222: lut = 16'd25350; 8'd223: lut = 16'd26090; 8'd224: lut = 16'd26852; 8'd225: lut = 16'd27636; 8'd226: lut = 16'd28443; 8'd227: lut = 16'd29273;
            8'd228: lut = 16'd30128; 8'd229: lut = 16'd31008; 8'd230: lut = 16'd31913; 8'd231: lut = 16'd32845; 8'd232: lut = 16'd33804; 8'd233: lut = 16'd34792;
            8'd234: lut = 16'd35807; 8'd235: lut = 16'd36853; 8'd236: lut = 16'd37929; 8'd237: lut = 16'd39037; 8'd238: lut = 16'd40177; 8'd239: lut = 16'd41350;
            8'd240: lut = 16'd42557; 8'd241: lut = 16'd43800; 8'd242: lut = 16'd45079; 8'd243: lut = 16'd46395; 8'd244: lut = 16'd47750; 8'd245: lut = 16'd49144;
            8'd246: lut = 16'd50579; 8'd247: lut = 16'd52056; 8'd248: lut = 16'd53576; 8'd249: lut = 16'd55141; 8'd250: lut = 16'd56751; 8'd251: lut = 16'd58408;
            8'd252: lut = 16'd60114; 8'd253: lut = 16'd61869; 8'd254: lut = 16'd63676; 8'd255: lut = 16'd65535;
            default: lut = 16'd0;
        endcase
        end
    endfunction

    // continuous assign: evaluated at time 0, so gain is never X
    assign gain = lut(sel);
endmodule
`default_nettype none
// ---------------------------------------------------------------
// One audio voice: 32-bit phase oscillator -> wave select -> volume.
// Output: 16-bit signed sample, updated once per `tick`.
//
// freq   : phase step per tick. Pitch = freq * fs / 2^32
//          (at fs = 48 kHz one step is 0.0000112 Hz; 440 Hz = 39370534)
// wave   : 0 sine          1 triangle      2 saw up       3 saw down
//          4 square        5 pulse (duty)  6 noise        7 organ
//          8 4-bit triangle (chip style)    9 4-bit saw (chip style)
//          10-15 silence
// duty   : pulse width for wave 5 (128 = 50%)
// volume : 8-bit picker, 0 = mute, 0.25 dB per step, 255 = full scale
// mute   : hard mute (fades out, no click)
//
// Volume changes slide at VOL_STEP gain units per tick instead of
// jumping, so there is no zipper noise or click.
// Noise steps its shift register each time the phase MSB toggles, so
// freq sets the noise colour (maximum freq = full-band white noise).
// ---------------------------------------------------------------
module audio_voice #(
    parameter [15:0] VOL_STEP = 16'd64
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,
    input  wire [31:0]        freq,
    input  wire [3:0]         wave,
    input  wire [7:0]         duty,
    input  wire [7:0]         volume,
    input  wire               mute,
    output reg  signed [15:0] sample
);
    reg  [31:0] phase;
    reg  [31:0] lfsr;
    reg  [15:0] vol_cur;

    // Advance the noise LFSR by 16 shifts at once, so every update gives
    // 16 brand-new bits (1 shift per update made neighbouring samples
    // x -> 2x, i.e. correlated and buzzy instead of white).
    function [31:0] lfsr_next16;
        input [31:0] s;
        integer n;
        reg [31:0] r;
        begin
            r = s;
            for (n = 0; n < 16; n = n + 1)
                r = {r[30:0], r[31] ^ r[21] ^ r[1] ^ r[0]};
            lfsr_next16 = r;
        end
    endfunction

    wire [31:0] phase_n = phase + freq;
    wire [15:0] ph      = phase[31:16];

    // ---- sine and harmonics (organ) ----
    wire signed [15:0] sine1, sine2, sine3;
    sine_lut s1 (.phase(phase),                          .sine(sine1));
    sine_lut s2 (.phase({phase[30:0], 1'b0}),            .sine(sine2));
    sine_lut s3 (.phase(phase + {phase[30:0], 1'b0}),    .sine(sine3));

    wire signed [17:0] organ_sum  = sine1 + (sine2 >>> 1) + (sine3 >>> 2);
    wire signed [35:0] organ_prod = organ_sum * 18'sd23500;      // about x0.717
    wire signed [15:0] organ      = organ_prod[30:15];

    // ---- simple shapes ----
    wire [15:0]        saw_u  = {~ph[15], ph[14:0]};
    wire signed [15:0] saw_up = saw_u;
    wire signed [15:0] saw_dn = ~saw_u;

    wire [14:0]        fold   = ph[15] ? ~ph[14:0] : ph[14:0];
    wire [15:0]        tri_u  = {fold, 1'b0};
    wire signed [15:0] tri_w    = tri_u ^ 16'h8000;

    wire [3:0]         qt_n   = fold[14:11];
    wire [15:0]        qt_u   = {qt_n, qt_n, qt_n, qt_n};
    wire signed [15:0] qtri   = qt_u ^ 16'h8000;

    wire [3:0]         qs_n   = ph[15:12];
    wire [15:0]        qs_u   = {qs_n, qs_n, qs_n, qs_n};
    wire signed [15:0] qsaw   = qs_u ^ 16'h8000;

    wire signed [15:0] square = ph[15] ? -16'sd32767 : 16'sd32767;
    wire signed [15:0] pulse  = (ph[15:8] < duty) ? 16'sd32767 : -16'sd32767;
    wire signed [15:0] noise  = lfsr[15:0];

    reg signed [15:0] raw;
    always @* begin
        case (wave)
            4'd0:    raw = sine1;
            4'd1:    raw = tri_w;
            4'd2:    raw = saw_up;
            4'd3:    raw = saw_dn;
            4'd4:    raw = square;
            4'd5:    raw = pulse;
            4'd6:    raw = noise;
            4'd7:    raw = organ;
            4'd8:    raw = qtri;
            4'd9:    raw = qsaw;
            default: raw = 16'sd0;
        endcase
    end

    // ---- volume ----
    wire [15:0] gain;
    vol_lut vl (.sel(volume), .gain(gain));
    wire [15:0] target = mute ? 16'd0 : gain;

    wire signed [32:0] scaled  = raw * $signed({1'b0, vol_cur});
    wire signed [32:0] rounded = scaled + 33'sd32768;

    always @(posedge clk) begin
        if (!rst_n) begin
            phase   <= 32'd0;
            lfsr    <= 32'hACE12468;     // any non-zero seed
            vol_cur <= 16'd0;
            sample  <= 16'sd0;
        end else if (tick) begin
            phase  <= phase_n;
            if (phase_n[31] != phase[31])
                lfsr <= lfsr_next16(lfsr);

            if (vol_cur < target)
                vol_cur <= (target - vol_cur > VOL_STEP) ? vol_cur + VOL_STEP : target;
            else if (vol_cur > target)
                vol_cur <= (vol_cur - target > VOL_STEP) ? vol_cur - VOL_STEP : target;

            sample <= rounded[31:16];
        end
    end
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Sample-rate tick: one 1-clock pulse every DIV clocks.
// fs = clk / DIV  (49.152 MHz / 1024 = 48 kHz)
// ---------------------------------------------------------------
module audio_tick #(
    parameter DIV = 1024
) (
    input  wire clk,
    input  wire rst_n,
    output reg  tick
);
    reg [31:0] cnt;
    always @(posedge clk) begin
        tick <= 1'b0;
        if (!rst_n) begin
            cnt <= 32'd0;
        end else if (cnt == DIV - 1) begin
            cnt  <= 32'd0;
            tick <= 1'b1;
        end else begin
            cnt <= cnt + 32'd1;
        end
    end
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Audio MIXER: sample tick -> 3 voices (wave + volume each) ->
// your accumulator (audio_core, 18 bits) -> MASTER volume -> clamp
// to 16 bits.
// Needs audio_mem.v, audio_adder.v, audio_core.v, sine_lut.v,
// vol_lut.v, audio_voice.v, audio_tick.v.
//
// Each sample the accumulator is cleared, voice 0, 1 and 2 are added
// in, then the sum goes through the master volume (same 0.25 dB
// curve, with a fade ramp so changes never click) and is clamped.
// Master volume acts BEFORE the clamp, so turning it down pulls an
// overloaded mix back into range.
// ---------------------------------------------------------------
module audio_chip #(
    parameter        DIV      = 1024,
    parameter [15:0] VOL_STEP = 16'd64
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire [31:0]        freq0,
    input  wire [3:0]         wave0,
    input  wire [7:0]         duty0,
    input  wire [7:0]         volume0,
    input  wire               mute0,

    input  wire [31:0]        freq1,
    input  wire [3:0]         wave1,
    input  wire [7:0]         duty1,
    input  wire [7:0]         volume1,
    input  wire               mute1,

    input  wire [31:0]        freq2,
    input  wire [3:0]         wave2,
    input  wire [7:0]         duty2,
    input  wire [7:0]         volume2,
    input  wire               mute2,

    input  wire [7:0]         master_vol,
    input  wire               master_mute,

    output reg  signed [15:0] sample_out
);
    wire tick;
    audio_tick #(.DIV(DIV)) tg (.clk(clk), .rst_n(rst_n), .tick(tick));

    wire signed [15:0] s0, s1, s2;

    audio_voice #(.VOL_STEP(VOL_STEP)) v0 (
        .clk(clk), .rst_n(rst_n), .tick(tick),
        .freq(freq0), .wave(wave0), .duty(duty0),
        .volume(volume0), .mute(mute0), .sample(s0)
    );
    audio_voice #(.VOL_STEP(VOL_STEP)) v1 (
        .clk(clk), .rst_n(rst_n), .tick(tick),
        .freq(freq1), .wave(wave1), .duty(duty1),
        .volume(volume1), .mute(mute1), .sample(s1)
    );
    audio_voice #(.VOL_STEP(VOL_STEP)) v2 (
        .clk(clk), .rst_n(rst_n), .tick(tick),
        .freq(freq2), .wave(wave2), .duty(duty2),
        .volume(volume2), .mute(mute2), .sample(s2)
    );

    // ---- accumulator (18 bits, signed) ----
    reg  [1:0]  acc_sel;
    reg  [17:0] acc_b;
    wire [17:0] acc_q;
    wire        acc_cout;
    audio_core #(.WIDTH(18)) acc (
        .clk(clk), .sel(acc_sel), .b(acc_b), .q(acc_q), .cout(acc_cout)
    );
    wire signed [17:0] acc_s = acc_q;

    // ---- master volume (fades, no clicks) ----
    wire [15:0] mgain;
    vol_lut ml (.sel(master_vol), .gain(mgain));
    wire [15:0] mtarget = master_mute ? 16'd0 : mgain;
    reg  [15:0] mcur;

    always @(posedge clk) begin
        if (!rst_n) begin
            mcur <= 16'd0;                     // fades in after reset
        end else if (tick) begin
            if (mcur < mtarget)
                mcur <= (mtarget - mcur > VOL_STEP) ? mcur + VOL_STEP : mtarget;
            else if (mcur > mtarget)
                mcur <= (mcur - mtarget > VOL_STEP) ? mcur - VOL_STEP : mtarget;
        end
    end

    wire signed [34:0] mprod = acc_s * $signed({1'b0, mcur});
    wire signed [34:0] mrnd  = mprod + 35'sd32768;
    wire signed [18:0] mixed = mrnd[34:16];
    wire signed [15:0] clamped =
        (mixed >  19'sd32767)  ? 16'sd32767 :
        (mixed < -19'sd32768)  ? -16'sd32768 :
                                 mixed[15:0];

    // one step per tick: clear, add v0, add v1, add v2, hold, latch
    reg       tick_d;
    reg [2:0] st;
    always @(posedge clk) begin
        if (!rst_n) begin
            tick_d     <= 1'b0;
            st         <= 3'd0;
            acc_sel    <= 2'b00;
            acc_b      <= 18'd0;
            sample_out <= 16'sd0;
        end else begin
            tick_d <= tick;            // voice samples are ready 1 clock after tick
            case (st)
                3'd0: if (tick_d) begin acc_sel <= 2'b01; st <= 3'd1; end
                3'd1: begin acc_sel <= 2'b10; acc_b <= {{2{s0[15]}}, s0}; st <= 3'd2; end
                3'd2: begin                   acc_b <= {{2{s1[15]}}, s1}; st <= 3'd3; end
                3'd3: begin                   acc_b <= {{2{s2[15]}}, s2}; st <= 3'd4; end
                3'd4: begin acc_sel <= 2'b00; st <= 3'd5; end
                3'd5: begin sample_out <= clamped; st <= 3'd0; end
                default: st <= 3'd0;
            endcase
        end
    end
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Audio CONTROL: CPU register bank + hardware switches.
//
// CPU bus (synchronous, 32-bit): bus_we writes bus_wdata to bus_addr
// on the clock edge; bus_rdata always shows the register at bus_addr.
//
//  addr  register     bits
//   0    CTRL         [0] master mute
//                     [3:1] voice 0/1/2 wave from switches
//                     [6:4] voice 0/1/2 volume from switches
//   1    MASTER_VOL   [7:0]
//   2    V0_FREQ      [31:0]  pitch = freq * fs / 2^32
//   3    V0_CFG       [3:0] wave  [11:4] duty  [19:12] volume  [20] mute
//   4    V1_FREQ      5  V1_CFG
//   6    V2_FREQ      7  V2_CFG
//
// CTRL bit map: bit0 = master mute, bit1/2/3 = voice 0/1/2 take WAVE
// from the switches, bit4/5/6 = voice 0/1/2 take VOLUME from the
// switches. Otherwise the register value is used.
//
// Switches:  sw_wave[3:0]  wave choice   sw_vol[7:0]  volume choice
//            sw_mute[2:0]  per-voice mute (always honoured, ORed with
//                          the register mute bit)
//
// Reset state is silent: every voice muted, volume 0, master 255,
// no switch overrides.
// ---------------------------------------------------------------
module audio_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // CPU register bus
    input  wire        bus_we,
    input  wire [2:0]  bus_addr,
    input  wire [31:0] bus_wdata,
    output reg  [31:0] bus_rdata,

    // switches
    input  wire [2:0]  sw_mute,
    input  wire [3:0]  sw_wave,
    input  wire [7:0]  sw_vol,

    // to the mixer
    output wire [31:0] freq0,   output wire [3:0] wave0,
    output wire [7:0]  duty0,   output wire [7:0] volume0,  output wire mute0,
    output wire [31:0] freq1,   output wire [3:0] wave1,
    output wire [7:0]  duty1,   output wire [7:0] volume1,  output wire mute1,
    output wire [31:0] freq2,   output wire [3:0] wave2,
    output wire [7:0]  duty2,   output wire [7:0] volume2,  output wire mute2,
    output wire [7:0]  master_vol,
    output wire        master_mute
);
    localparam [20:0] CFG_RESET = {1'b1, 8'd0, 8'd128, 4'd0};  // muted, vol 0, duty 50%, sine

    reg [6:0]  ctrl;
    reg [7:0]  master_r;
    reg [31:0] freq_r0, freq_r1, freq_r2;
    reg [20:0] cfg_r0,  cfg_r1,  cfg_r2;

    always @(posedge clk) begin
        if (!rst_n) begin
            ctrl     <= 7'd0;
            master_r <= 8'd255;
            freq_r0  <= 32'd0;  freq_r1 <= 32'd0;  freq_r2 <= 32'd0;
            cfg_r0   <= CFG_RESET;
            cfg_r1   <= CFG_RESET;
            cfg_r2   <= CFG_RESET;
        end else if (bus_we) begin
            case (bus_addr)
                3'd0: ctrl     <= bus_wdata[6:0];
                3'd1: master_r <= bus_wdata[7:0];
                3'd2: freq_r0  <= bus_wdata;
                3'd3: cfg_r0   <= bus_wdata[20:0];
                3'd4: freq_r1  <= bus_wdata;
                3'd5: cfg_r1   <= bus_wdata[20:0];
                3'd6: freq_r2  <= bus_wdata;
                3'd7: cfg_r2   <= bus_wdata[20:0];
            endcase
        end
    end

    always @* begin
        case (bus_addr)
            3'd0:    bus_rdata = {25'd0, ctrl};
            3'd1:    bus_rdata = {24'd0, master_r};
            3'd2:    bus_rdata = freq_r0;
            3'd3:    bus_rdata = {11'd0, cfg_r0};
            3'd4:    bus_rdata = freq_r1;
            3'd5:    bus_rdata = {11'd0, cfg_r1};
            3'd6:    bus_rdata = freq_r2;
            3'd7:    bus_rdata = {11'd0, cfg_r2};
            default: bus_rdata = 32'd0;
        endcase
    end

    assign master_vol  = master_r;
    assign master_mute = ctrl[0];

    assign freq0 = freq_r0;
    assign freq1 = freq_r1;
    assign freq2 = freq_r2;

    assign wave0 = ctrl[1] ? sw_wave : cfg_r0[3:0];
    assign wave1 = ctrl[2] ? sw_wave : cfg_r1[3:0];
    assign wave2 = ctrl[3] ? sw_wave : cfg_r2[3:0];

    assign duty0 = cfg_r0[11:4];
    assign duty1 = cfg_r1[11:4];
    assign duty2 = cfg_r2[11:4];

    assign volume0 = ctrl[4] ? sw_vol : cfg_r0[19:12];
    assign volume1 = ctrl[5] ? sw_vol : cfg_r1[19:12];
    assign volume2 = ctrl[6] ? sw_vol : cfg_r2[19:12];

    assign mute0 = cfg_r0[20] | sw_mute[0];
    assign mute1 = cfg_r1[20] | sw_mute[1];
    assign mute2 = cfg_r2[20] | sw_mute[2];
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Audio chip top: CPU register bus + switches -> 3-voice mixer.
// Needs everything: audio_mem.v audio_adder.v audio_core.v sine_lut.v
// vol_lut.v audio_voice.v audio_tick.v audio_chip.v audio_ctrl.v
// ---------------------------------------------------------------
module audio_top #(
    parameter DIV = 1024            // fs = clk / DIV (49.152 MHz / 1024 = 48 kHz)
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               bus_we,
    input  wire [2:0]         bus_addr,
    input  wire [31:0]        bus_wdata,
    output wire [31:0]        bus_rdata,

    input  wire [2:0]         sw_mute,
    input  wire [3:0]         sw_wave,
    input  wire [7:0]         sw_vol,

    output wire signed [15:0] sample_out
);
    wire [31:0] freq0, freq1, freq2;
    wire [3:0]  wave0, wave1, wave2;
    wire [7:0]  duty0, duty1, duty2, volume0, volume1, volume2, master_vol;
    wire        mute0, mute1, mute2, master_mute;

    audio_ctrl ctrl (
        .clk(clk), .rst_n(rst_n),
        .bus_we(bus_we), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .sw_mute(sw_mute), .sw_wave(sw_wave), .sw_vol(sw_vol),
        .freq0(freq0), .wave0(wave0), .duty0(duty0), .volume0(volume0), .mute0(mute0),
        .freq1(freq1), .wave1(wave1), .duty1(duty1), .volume1(volume1), .mute1(mute1),
        .freq2(freq2), .wave2(wave2), .duty2(duty2), .volume2(volume2), .mute2(mute2),
        .master_vol(master_vol), .master_mute(master_mute)
    );

    audio_chip #(.DIV(DIV)) mixer (
        .clk(clk), .rst_n(rst_n),
        .freq0(freq0), .wave0(wave0), .duty0(duty0), .volume0(volume0), .mute0(mute0),
        .freq1(freq1), .wave1(wave1), .duty1(duty1), .volume1(volume1), .mute1(mute1),
        .freq2(freq2), .wave2(wave2), .duty2(duty2), .volume2(volume2), .mute2(mute2),
        .master_vol(master_vol), .master_mute(master_mute),
        .sample_out(sample_out)
    );
endmodule
`default_nettype none
// ---------------------------------------------------------------
// Audio chip, serial-interface version (10 signal pins).
// Needs everything in audio_test_fixed.v (audio_top and below).
//
//   Control : SPI slave, mode 0 (CPOL=0, CPHA=0), MSB first, 40-bit frame
//             byte 0   = {rw, 4'b0000, addr[2:0]}   rw: 1 = read, 0 = write
//             bytes 1-4 = 32-bit data (write: host -> chip, read: chip -> host)
//             Same register map as audio_ctrl (addr 0..7).
//             SCK must be no faster than clk / 4.
//   Audio   : I2S master, 16-bit data in 32-bit slots, mono sample sent
//             on both channels. BCLK = clk/16, LRCLK = clk/1024
//             (49.152 MHz clk -> BCLK 3.072 MHz, LRCLK 48 kHz).
//   MUTE    : hardware mute input, mutes all three voices (fades, no click).
//
// The per-voice switch override bits in CTRL are not usable in this
// version (sw_wave and sw_vol are tied to 0); use the registers.
// ---------------------------------------------------------------

// ---------------- SPI slave -> register bus ----------------
module spi_regbus (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sck,
    input  wire        cs_n,
    input  wire        mosi,
    output wire        miso,
    output wire        miso_d,
    output wire        miso_oe,
    output reg         bus_we,
    output reg  [2:0]  bus_addr,
    output reg  [31:0] bus_wdata,
    input  wire [31:0] bus_rdata
);
    reg [2:0]  sck_q;
    reg [2:0]  mosi_q;
    reg [1:0]  cs_q;
    reg [31:0] sh_in;
    reg [31:0] out_sh;
    reg [5:0]  bitcnt;      // rising SCK edges seen in this frame (saturates at 40)
    reg        rw_r;

    wire sck_rise = (sck_q[2:1] == 2'b01);
    wire sck_fall = (sck_q[2:1] == 2'b10);
    wire active   = ~cs_q[1];
    wire mosi_s   = mosi_q[1];

    always @(posedge clk) begin
        if (!rst_n) begin
            sck_q     <= 3'b000;
            mosi_q    <= 3'b000;
            cs_q      <= 2'b11;
            sh_in     <= 32'd0;
            out_sh    <= 32'd0;
            bitcnt    <= 6'd0;
            rw_r      <= 1'b0;
            bus_we    <= 1'b0;
            bus_addr  <= 3'd0;
            bus_wdata <= 32'd0;
        end else begin
            sck_q  <= {sck_q[1:0], sck};
            mosi_q <= {mosi_q[1:0], mosi};
            cs_q   <= {cs_q[0], cs_n};
            bus_we <= 1'b0;                       // one-clock write pulse

            if (!active) begin
                bitcnt <= 6'd0;
            end else begin
                if (sck_rise) begin
                    sh_in <= {sh_in[30:0], mosi_s};
                    if (bitcnt < 6'd40) bitcnt <= bitcnt + 6'd1;

                    if (bitcnt == 6'd7) begin     // 8th bit: command byte complete
                        rw_r     <= sh_in[6];
                        bus_addr <= {sh_in[1:0], mosi_s};
                    end

                    if (bitcnt == 6'd39 && !rw_r) begin   // 40th bit: write data complete
                        bus_wdata <= {sh_in[30:0], mosi_s};
                        bus_we    <= 1'b1;
                    end
                end

                if (sck_fall) begin
                    if (bitcnt == 6'd8)
                        out_sh <= bus_rdata;      // load read data (bus_addr is stable)
                    else if (bitcnt > 6'd8)
                        out_sh <= {out_sh[30:0], 1'b0};
                end
            end
        end
    end

    assign miso_d  = out_sh[31];
    assign miso_oe = ~cs_n;
    assign miso    = miso_oe ? miso_d : 1'bz;     // tri-state when not selected
endmodule

// ---------------- I2S transmitter (master) ----------------
module i2s_tx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire signed [15:0] sample,
    output reg                bclk,
    output reg                lrclk,
    output reg                sdout
);
    reg [2:0]  div;      // half-BCLK = 8 clk
    reg [5:0]  fc;       // BCLK slot in the 64-slot frame
    reg [15:0] word;
    wire [4:0] pos = fc[4:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            div   <= 3'd0;
            fc    <= 6'd0;
            word  <= 16'd0;
            bclk  <= 1'b0;
            lrclk <= 1'b0;
            sdout <= 1'b0;
        end else begin
            div <= div + 3'd1;
            if (div == 3'd7) begin
                bclk <= ~bclk;
                if (bclk) begin                   // falling edge of BCLK
                    lrclk <= fc[5];               // 0 = left, 1 = right
                    if (fc == 6'd0) word <= sample;
                    // I2S: MSB comes one BCLK after the LRCLK change
                    if (pos >= 5'd1 && pos <= 5'd16)
                        sdout <= word[5'd16 - pos];
                    else
                        sdout <= 1'b0;
                    fc <= fc + 6'd1;
                end
            end
        end
    end
endmodule

// ---------------- Tiny Tapeout wrapper ----------------
// ui_in[0]=MUTE  ui_in[1]=SCK  ui_in[2]=CS_N  ui_in[3]=MOSI
// uo_out[0]=BCLK uo_out[1]=LRCLK uo_out[2]=SDOUT
// uio[0]=MISO (output enable = CS_N low)
module tt_um_audio_chip_gen1 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    wire        mute = ui_in[0];
    wire        sck  = ui_in[1];
    wire        cs_n = ui_in[2];
    wire        mosi = ui_in[3];

    wire        bus_we;
    wire [2:0]  bus_addr;
    wire [31:0] bus_wdata;
    wire [31:0] bus_rdata;
    wire signed [15:0] sample_w;
    wire        miso_d, miso_oe;
    wire        bclk, lrclk, sdout;

    spi_regbus spi (
        .clk(clk), .rst_n(rst_n),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(),
        .miso_d(miso_d), .miso_oe(miso_oe),
        .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_rdata(bus_rdata)
    );

    audio_top #(.DIV(1024)) core (
        .clk(clk), .rst_n(rst_n),
        .bus_we(bus_we), .bus_addr(bus_addr),
        .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .sw_mute({3{mute}}), .sw_wave(4'd0), .sw_vol(8'd0),
        .sample_out(sample_w)
    );

    i2s_tx i2s (
        .clk(clk), .rst_n(rst_n), .sample(sample_w),
        .bclk(bclk), .lrclk(lrclk), .sdout(sdout)
    );

    assign uo_out  = {5'b00000, sdout, lrclk, bclk};
    assign uio_out = {7'b0000000, miso_d};
    assign uio_oe  = {7'b0000000, miso_oe};

    wire _unused = &{ena, uio_in, ui_in[7:4], 1'b0};
endmodule
