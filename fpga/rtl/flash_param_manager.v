`timescale 1ns / 1ps
`default_nettype none

// W25Q128 parameter manager.
//
// Safety invariant: this module can only erase/program address 0x800000 or
// 0xC00000.  There is no chip-erase opcode in the RTL.  The 64-byte record is
// staged with Commit=0xffffffff and committed by a final four-byte program.
module flash_param_manager #(
    parameter integer STARTUP_WAIT_CYCLES = 32000,
    // If EOS/JEDEC/parameter reads never complete after a QSPI boot, release
    // the network with safe RTL defaults instead of holding the whole design
    // behind flash_busy forever. SAVE remains blocked by flash_error.
    parameter integer BOOT_TIMEOUT_CYCLES = 64000000,
    // A parameter save includes a 4-KiB sector erase.  The W25Q128 erase
    // operation is asynchronous and can be much longer on real silicon than
    // the byte-level SPI transfers.  Keep the watchdog well above the device
    // maximum while still detecting a genuinely stuck flash.
    parameter integer OP_TIMEOUT_CYCLES = 256000000,
    parameter integer DEBUG_JEDEC_RETRY = 0,
    parameter integer DEBUG_RETRY_CYCLES = 16000000,
    parameter [23:0] PARAM_A_ADDR = 24'h800000,
    parameter [23:0] PARAM_B_ADDR = 24'hC00000,
    parameter [223:0] DEFAULT_CONFIG = {
        32'hC0A80002,32'hFFFFFF00,32'hC0A80003,16'd56555,16'd0,
        32'd500000,32'h00FFFFFF,32'd30}
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         save_req,
    input  wire [223:0] save_config,
    output reg          save_done,
    output reg  [3:0]   save_status,
    output reg          boot_done,
    output reg  [223:0] active_config,
    output reg          config_from_flash,
    output reg  [31:0]  active_sequence,
    output reg  [1:0]   active_copy,
    output reg  [23:0]  jedec_id,
    output reg          flash_error,
    output reg  [7:0]   flash_error_code,
    output wire         flash_busy,
    output wire         flash_cs_n,
    output wire         flash_dq0,
    input  wire         flash_dq1,
    output wire         startup_eos,
    output wire         debug_eos_seen,
    output wire [6:0]   debug_state,
    output wire         debug_cs_active,
    output wire         debug_spi_clk,
    output wire         debug_byte_start,
    output wire         debug_byte_busy,
    output wire         debug_byte_done,
    output wire [7:0]   debug_tx_byte,
    output wire [7:0]   debug_rx_byte,
    output wire [3:0]   debug_edge_count,
    output wire [6:0]   debug_byte_index,
    output reg  [31:0]  debug_jedec_attempt_count
);
    localparam [31:0] MAGIC = 32'h41444346; // "ADCF"
    localparam [31:0] COMMIT = 32'hC04D4D17;
    localparam [3:0] SAVE_OK=0, SAVE_FLASH_ERROR=7,
                     SAVE_VERIFY_ERROR=8, SAVE_TIMEOUT=9;
    localparam [7:0] E_NONE=0,E_JEDEC=1,E_TIMEOUT=2,E_FIREWALL=3,E_VERIFY=4;

    localparam [6:0]
      S_EOS=0,S_JEDEC_CMD=1,S_JEDEC_READ=2,S_READ_A_CMD=3,S_READ_A_ADDR=4,
      S_READ_A_DATA=5,S_READ_B_CMD=6,S_READ_B_ADDR=7,S_READ_B_DATA=8,
      S_SELECT=9,S_IDLE=10,S_WREN_E=11,S_ERASE_CMD=12,S_ERASE_ADDR=13,
      S_POLL_CMD=14,S_POLL_READ=15,S_WREN_P=16,S_PP_CMD=17,S_PP_ADDR=18,
      S_PP_DATA=19,S_VERIFY_CMD=20,S_VERIFY_ADDR=21,S_VERIFY_DATA=22,
      S_WREN_C=23,S_COMMIT_CMD=24,S_COMMIT_ADDR=25,S_COMMIT_DATA=26,
      S_FINAL_CMD=27,S_FINAL_ADDR=28,S_FINAL_DATA=29,S_FINISH=30,S_FAIL=31,
      S_GAP=32,S_DEBUG_RETRY_WAIT=33,S_BOOT_RETRY=34,S_SAVE_CRC=35,S_SAVE_HCRC=36;

    reg [6:0] state, return_after_poll, gap_next;
    reg [31:0] wait_count, timeout_count;
    reg [31:0] boot_timeout_count;
    reg cs_active, byte_start;
    reg [7:0] tx_byte;
    wire [7:0] rx_byte;
    wire byte_done, byte_busy;
    reg [6:0] byte_index;
    reg [1:0] addr_index;
    reg [23:0] work_addr;
    wire [23:0] commit_addr = work_addr + 24;
    reg [223:0] pending_config;
    reg [31:0] pending_sequence;
    reg [31:0] pending_pcrc,pending_hcrc;
    reg [511:0] record_a, record_b, verify_record;
    reg valid_a, valid_b;
    reg [31:0] seq_a, seq_b;
    reg [223:0] cfg_a, cfg_b;
    reg op_is_save;
    reg eos_seen;
    (* ASYNC_REG = "TRUE" *) reg [1:0] eos_sync;
    wire spi_ready;
    always @(posedge clk or posedge rst) begin
      if(rst) eos_sync <= 0;
      else eos_sync <= {eos_sync[0],startup_eos};
    end
    reg debug_retry_transaction;

    assign debug_eos_seen = eos_seen;
    assign debug_state = state;
    assign debug_cs_active = cs_active;
    assign debug_byte_start = byte_start;
    assign debug_byte_busy = byte_busy;
    assign debug_byte_done = byte_done;
    assign debug_tx_byte = tx_byte;
    assign debug_rx_byte = rx_byte;
    assign debug_byte_index = byte_index;

    // The diagnostic wait state is deliberately reported idle so a failed
    // JEDEC probe cannot prevent the normal network/ADC path reaching READY.
    assign flash_busy = !boot_done || (state != S_IDLE && state != S_DEBUG_RETRY_WAIT);

    flash_spi_byte_master #(.STARTUP_WAIT_CYCLES(STARTUP_WAIT_CYCLES)) u_spi (
        .clk(clk),.rst(rst),.enable(eos_seen),.cs_active(cs_active),
        .byte_start(byte_start),.tx_byte(tx_byte),.rx_byte(rx_byte),
        .byte_done(byte_done),.busy(byte_busy),.flash_cs_n(flash_cs_n),
        .flash_dq0(flash_dq0),.flash_dq1(flash_dq1),.flash_clk(debug_spi_clk),
        .eos(startup_eos),.spi_ready(spi_ready),.debug_edge_count(debug_edge_count));

    function automatic [31:0] crc_byte;
      input [31:0] crc_in; input [7:0] din; integer n; reg [31:0] c;
      begin c=crc_in^din;for(n=0;n<8;n=n+1)c=c[0]?(c>>1)^32'hEDB88320:(c>>1);crc_byte=c;end
    endfunction
    function automatic [7:0] cfg_byte;
      input [223:0] cfg; input integer n;
      begin cfg_byte=cfg[223-n*8 -: 8]; end
    endfunction
    function automatic [31:0] payload_crc;
      input [223:0] cfg; integer n,j; reg [31:0] c;
      begin
        c=32'hffffffff;
        for(n=0;n<28;n=n+1)begin
          c=c ^ {24'd0,cfg[223-n*8 -:8]};
          for(j=0;j<8;j=j+1)c=c[0]?(c>>1)^32'hEDB88320:(c>>1);
        end
        payload_crc=~c;
      end
    endfunction
    function automatic [31:0] header_crc;
      input [31:0] seq; input [31:0] pcrc; integer n; reg [31:0] c; reg [7:0] b;
      begin
        c=32'hffffffff;
        for(n=0;n<20;n=n+1)begin
          case(n)
            0:b=8'h41;1:b=8'h44;2:b=8'h43;3:b=8'h46;
            4:b=0;5:b=1;6:b=0;7:b=32;
            8:b=seq[31:24];9:b=seq[23:16];10:b=seq[15:8];11:b=seq[7:0];
            12:b=0;13:b=0;14:b=0;15:b=28;
            16:b=pcrc[31:24];17:b=pcrc[23:16];18:b=pcrc[15:8];default:b=pcrc[7:0];
          endcase
          c=crc_byte(c,b);
        end
        // Reserved word (bytes 28..31) is part of the protected header.
        for(n=0;n<4;n=n+1)c=crc_byte(c,8'h00);
        header_crc=~c;
      end
    endfunction
    function [7:0] record_byte;
      input [223:0] cfg; input [31:0] seq; input [31:0] pc;input [31:0] hc;input integer n; input commit_enable;
      begin
        case(n)
          0:record_byte=8'h41;1:record_byte=8'h44;2:record_byte=8'h43;3:record_byte=8'h46;
          4:record_byte=0;5:record_byte=1;6:record_byte=0;7:record_byte=32;
          8:record_byte=seq[31:24];9:record_byte=seq[23:16];10:record_byte=seq[15:8];11:record_byte=seq[7:0];
          12:record_byte=0;13:record_byte=0;14:record_byte=0;15:record_byte=28;
          16:record_byte=pc[31:24];17:record_byte=pc[23:16];18:record_byte=pc[15:8];19:record_byte=pc[7:0];
          20:record_byte=hc[31:24];21:record_byte=hc[23:16];22:record_byte=hc[15:8];23:record_byte=hc[7:0];
          24:record_byte=commit_enable?COMMIT[31:24]:8'hff;
          25:record_byte=commit_enable?COMMIT[23:16]:8'hff;
          26:record_byte=commit_enable?COMMIT[15:8]:8'hff;
          27:record_byte=commit_enable?COMMIT[7:0]:8'hff;
          28,29,30,31,60,61,62,63:record_byte=0;
          default:record_byte=(n>=32&&n<60)?cfg_byte(cfg,n-32):8'h00;
        endcase
      end
    endfunction
    function [7:0] vector_byte;
      input [511:0] vec; input integer n;
      begin vector_byte=vec[511-n*8 -: 8];end
    endfunction
    function record_valid;
      input [511:0] vec; integer n; reg [223:0] cf; reg [31:0] sq,pc,hc;
      begin
        for(n=0;n<28;n=n+1)cf[223-n*8 -:8]=vector_byte(vec,n+32);
        sq={vector_byte(vec,8),vector_byte(vec,9),vector_byte(vec,10),vector_byte(vec,11)};
        pc={vector_byte(vec,16),vector_byte(vec,17),vector_byte(vec,18),vector_byte(vec,19)};
        hc={vector_byte(vec,20),vector_byte(vec,21),vector_byte(vec,22),vector_byte(vec,23)};
        record_valid={vector_byte(vec,0),vector_byte(vec,1),vector_byte(vec,2),vector_byte(vec,3)}==MAGIC &&
          {vector_byte(vec,4),vector_byte(vec,5)}==16'd1 &&
          {vector_byte(vec,6),vector_byte(vec,7)}==16'd32 &&
          {vector_byte(vec,12),vector_byte(vec,13),vector_byte(vec,14),vector_byte(vec,15)}==32'd28 &&
          {vector_byte(vec,24),vector_byte(vec,25),vector_byte(vec,26),vector_byte(vec,27)}==COMMIT &&
          pc==payload_crc(cf) && hc==header_crc(sq,pc);
      end
    endfunction
    function [223:0] vector_config;
      input [511:0] vec; integer n;
      begin for(n=0;n<28;n=n+1)vector_config[223-n*8 -:8]=vector_byte(vec,n+32);end
    endfunction
    function [31:0] vector_sequence;
      input [511:0] vec;
      begin vector_sequence={vector_byte(vec,8),vector_byte(vec,9),vector_byte(vec,10),vector_byte(vec,11)};end
    endfunction
    function address_allowed;
      input [23:0] a;
      begin address_allowed=(a==PARAM_A_ADDR)||(a==PARAM_B_ADDR);end
    endfunction
    function config_valid;
      input [223:0] cf;integer k;integer count;reg [31:0] lip,nm,dip,rate,mask,gpp;reg [15:0] port;
      begin
        lip=cf[223:192];nm=cf[191:160];dip=cf[159:128];port=cf[127:112];rate=cf[95:64];mask=cf[63:32];gpp=cf[31:0];
        count=0;for(k=0;k<24;k=k+1)count=count+mask[k];
        config_valid=lip!=0&&lip!=32'hffffffff&&dip!=0&&dip!=32'hffffffff&&lip!=dip&&
          nm!=0&&(((~nm)&((~nm)+1))==0)&&((lip&nm)==(dip&nm))&&port!=0&&
          ((rate==250000)||(rate==500000)||(rate==1000000))&&
          mask[31:24]==0&&count>0&&gpp>=1&&gpp<=30;
      end
    endfunction

    task start_byte;
      input [7:0] b;
      begin tx_byte<=b;byte_start<=1'b1;end
    endtask
    task fail_operation;
      input [7:0] code; input [3:0] status;
      begin flash_error<=1;flash_error_code<=code;save_status<=status;state<=S_FAIL;cs_active<=0;end
    endtask
    task goto_gap;
      input [6:0] next_state;
      begin cs_active<=0;gap_next<=next_state;state<=S_GAP;end
    endtask

    always @(posedge clk) begin
      if(rst)begin
        state<=S_EOS;wait_count<=0;timeout_count<=0;cs_active<=0;byte_start<=0;tx_byte<=8'hff;
        byte_index<=0;addr_index<=0;work_addr<=0;pending_config<=DEFAULT_CONFIG;pending_sequence<=1;pending_pcrc<=0;pending_hcrc<=0;
        record_a<={512{1'b1}};record_b<={512{1'b1}};verify_record<={512{1'b1}};
        valid_a<=0;valid_b<=0;seq_a<=0;seq_b<=0;cfg_a<=DEFAULT_CONFIG;cfg_b<=DEFAULT_CONFIG;
        save_done<=0;save_status<=0;boot_done<=0;active_config<=DEFAULT_CONFIG;
        boot_timeout_count<=0;
        config_from_flash<=0;active_sequence<=0;active_copy<=0;jedec_id<=0;
        flash_error<=0;flash_error_code<=E_NONE;return_after_poll<=S_IDLE;gap_next<=S_IDLE;op_is_save<=0;eos_seen<=0;
        debug_retry_transaction<=0;debug_jedec_attempt_count<=0;
      end else begin
        byte_start<=0;save_done<=0;
        if(!boot_done && boot_timeout_count < BOOT_TIMEOUT_CYCLES)
          boot_timeout_count<=boot_timeout_count+1'b1;
        if(!boot_done && boot_timeout_count>=BOOT_TIMEOUT_CYCLES-1) begin
          // The QSPI startup path is not allowed to make the network
          // permanently disappear.  Do not claim the parameters are valid;
          // expose the timeout and keep SAVE disabled until a fresh boot.
          boot_done<=1; active_config<=DEFAULT_CONFIG; active_sequence<=0;
          active_copy<=0; config_from_flash<=0;
          flash_error<=1; flash_error_code<=E_TIMEOUT;
          save_status<=SAVE_TIMEOUT; cs_active<=0; op_is_save<=0;
          state<=S_IDLE;
        end else if(state!=S_IDLE && state!=S_EOS && state!=S_DEBUG_RETRY_WAIT && state!=S_BOOT_RETRY)
          timeout_count<=timeout_count+1'b1;
        else timeout_count<=0;
        if(!(!boot_done && boot_timeout_count>=BOOT_TIMEOUT_CYCLES-1) && timeout_count>=OP_TIMEOUT_CYCLES)fail_operation(E_TIMEOUT,SAVE_TIMEOUT);
        else if(!(!boot_done && boot_timeout_count>=BOOT_TIMEOUT_CYCLES-1)) case(state)
          S_EOS:begin
            if(eos_sync[1])eos_seen<=1;
            if(spi_ready)begin wait_count<=0;cs_active<=1;state<=S_JEDEC_CMD;end
          end
          S_JEDEC_CMD:if(!byte_busy&&!byte_start)start_byte(8'h9f);else if(byte_done)begin byte_index<=0;state<=S_JEDEC_READ;end
          S_JEDEC_READ:if(!byte_busy&&!byte_start)start_byte(8'hff);else if(byte_done)begin
            jedec_id<={jedec_id[15:0],rx_byte};
            if(byte_index==2)begin
              debug_jedec_attempt_count<=debug_jedec_attempt_count+1'b1;
              if(debug_retry_transaction)begin
                // A retry is observation-only: never load or save parameters
                // after the normal boot decision has already completed.
                cs_active<=0;wait_count<=0;state<=S_DEBUG_RETRY_WAIT;
              end else if({jedec_id[15:0],rx_byte}!=24'hEF4018)begin
                if(debug_jedec_attempt_count < 2)begin
                  cs_active<=0;wait_count<=0;state<=S_BOOT_RETRY;
                end else begin
                cs_active<=0;flash_error<=1;flash_error_code<=E_JEDEC;
                active_config<=DEFAULT_CONFIG;boot_done<=1;wait_count<=0;
                if(DEBUG_JEDEC_RETRY!=0)state<=S_DEBUG_RETRY_WAIT;else state<=S_IDLE;
                end
              end else goto_gap(S_READ_A_CMD);
            end else byte_index<=byte_index+1'b1;
          end
          S_READ_A_CMD:if(!byte_busy&&!byte_start)start_byte(8'h03);else if(byte_done)begin addr_index<=0;state<=S_READ_A_ADDR;end
          S_READ_A_ADDR:if(!byte_busy&&!byte_start)start_byte(PARAM_A_ADDR[23-addr_index*8 -:8]);else if(byte_done)begin if(addr_index==2)begin byte_index<=0;state<=S_READ_A_DATA;end else addr_index<=addr_index+1'b1;end
          S_READ_A_DATA:if(!byte_busy&&!byte_start)start_byte(8'hff);else if(byte_done)begin
            record_a[511-byte_index*8 -:8]<=rx_byte;
            if(byte_index==63)goto_gap(S_READ_B_CMD);else byte_index<=byte_index+1'b1;
          end
          S_READ_B_CMD:if(!byte_busy&&!byte_start)start_byte(8'h03);else if(byte_done)begin addr_index<=0;state<=S_READ_B_ADDR;end
          S_READ_B_ADDR:if(!byte_busy&&!byte_start)start_byte(PARAM_B_ADDR[23-addr_index*8 -:8]);else if(byte_done)begin if(addr_index==2)begin byte_index<=0;state<=S_READ_B_DATA;end else addr_index<=addr_index+1'b1;end
          S_READ_B_DATA:if(!byte_busy&&!byte_start)start_byte(8'hff);else if(byte_done)begin
            record_b[511-byte_index*8 -:8]<=rx_byte;
            if(byte_index==63)begin cs_active<=0;state<=S_SELECT;end else byte_index<=byte_index+1'b1;
          end
          S_SELECT:begin
            valid_a<=record_valid(record_a);valid_b<=record_valid(record_b);
            seq_a<=vector_sequence(record_a);seq_b<=vector_sequence(record_b);
            cfg_a<=vector_config(record_a);cfg_b<=vector_config(record_b);
            if(record_valid(record_a)&&config_valid(vector_config(record_a))&&
              (!(record_valid(record_b)&&config_valid(vector_config(record_b)))||$signed(vector_sequence(record_a)-vector_sequence(record_b))>0))begin
              active_config<=vector_config(record_a);active_sequence<=vector_sequence(record_a);active_copy<=1;config_from_flash<=1;
            end else if(record_valid(record_b)&&config_valid(vector_config(record_b)))begin
              active_config<=vector_config(record_b);active_sequence<=vector_sequence(record_b);active_copy<=2;config_from_flash<=1;
            end else begin active_config<=DEFAULT_CONFIG;active_sequence<=0;active_copy<=0;config_from_flash<=0;end
            boot_done<=1;state<=S_IDLE;
          end
          S_IDLE:if(save_req)begin
            if(flash_error)begin save_status<=SAVE_FLASH_ERROR;save_done<=1;end
            else begin pending_config<=save_config;pending_sequence<=active_sequence+1'b1;
              work_addr<=(active_copy==1)?PARAM_B_ADDR:PARAM_A_ADDR;
              if(!address_allowed((active_copy==1)?PARAM_B_ADDR:PARAM_A_ADDR))fail_operation(E_FIREWALL,SAVE_FLASH_ERROR);
              else begin op_is_save<=1;state<=S_SAVE_CRC;end
            end
          end
          S_SAVE_CRC:begin pending_pcrc<=payload_crc(pending_config);state<=S_SAVE_HCRC;end
          S_SAVE_HCRC:begin pending_hcrc<=header_crc(pending_sequence,pending_pcrc);cs_active<=1;state<=S_WREN_E;end
          S_BOOT_RETRY:begin
            if(wait_count==DEBUG_RETRY_CYCLES-1)begin
              wait_count<=0;jedec_id<=0;cs_active<=1;state<=S_JEDEC_CMD;
            end else wait_count<=wait_count+1'b1;
          end
          S_DEBUG_RETRY_WAIT:begin
            // SAVE remains rejected exactly as it is in S_IDLE after a JEDEC
            // failure, while the observation-only retry timer is waiting.
            if(save_req)begin
              save_status<=SAVE_FLASH_ERROR;save_done<=1;
            end
            if(wait_count==DEBUG_RETRY_CYCLES-1)begin
              wait_count<=0;byte_index<=0;jedec_id<=0;
              debug_retry_transaction<=1;cs_active<=1;state<=S_JEDEC_CMD;
            end else wait_count<=wait_count+1'b1;
          end
          S_WREN_E:if(!byte_busy&&!byte_start)start_byte(8'h06);else if(byte_done)goto_gap(S_ERASE_CMD);
          S_ERASE_CMD:if(!address_allowed(work_addr))fail_operation(E_FIREWALL,SAVE_FLASH_ERROR);else if(!byte_busy&&!byte_start)start_byte(8'h20);else if(byte_done)begin addr_index<=0;state<=S_ERASE_ADDR;end
          S_ERASE_ADDR:if(!byte_busy&&!byte_start)start_byte(work_addr[23-addr_index*8 -:8]);else if(byte_done)begin if(addr_index==2)begin return_after_poll<=S_WREN_P;goto_gap(S_POLL_CMD);end else addr_index<=addr_index+1'b1;end
          S_POLL_CMD:if(!byte_busy&&!byte_start)start_byte(8'h05);else if(byte_done)state<=S_POLL_READ;
          S_POLL_READ:if(!byte_busy&&!byte_start)start_byte(8'hff);else if(byte_done)begin if(rx_byte[0])goto_gap(S_POLL_CMD);else goto_gap(return_after_poll);end
          S_WREN_P:if(!byte_busy&&!byte_start)start_byte(8'h06);else if(byte_done)goto_gap(S_PP_CMD);
          S_PP_CMD:if(!address_allowed(work_addr))fail_operation(E_FIREWALL,SAVE_FLASH_ERROR);else if(!byte_busy&&!byte_start)start_byte(8'h02);else if(byte_done)begin addr_index<=0;state<=S_PP_ADDR;end
          S_PP_ADDR:if(!byte_busy&&!byte_start)start_byte(work_addr[23-addr_index*8 -:8]);else if(byte_done)begin if(addr_index==2)begin byte_index<=0;state<=S_PP_DATA;end else addr_index<=addr_index+1'b1;end
          S_PP_DATA:if(!byte_busy&&!byte_start)start_byte(record_byte(pending_config,pending_sequence,pending_pcrc,pending_hcrc,byte_index,1'b0));else if(byte_done)begin
            if(byte_index==63)begin return_after_poll<=S_VERIFY_CMD;goto_gap(S_POLL_CMD);end else byte_index<=byte_index+1'b1;
          end
          S_VERIFY_CMD:if(!byte_busy&&!byte_start)start_byte(8'h03);else if(byte_done)begin addr_index<=0;state<=S_VERIFY_ADDR;end
          S_VERIFY_ADDR:if(!byte_busy&&!byte_start)start_byte(work_addr[23-addr_index*8 -:8]);else if(byte_done)begin if(addr_index==2)begin byte_index<=0;state<=S_VERIFY_DATA;end else addr_index<=addr_index+1'b1;end
          S_VERIFY_DATA:if(!byte_busy&&!byte_start)start_byte(8'hff);else if(byte_done)begin
            if(rx_byte!=record_byte(pending_config,pending_sequence,pending_pcrc,pending_hcrc,byte_index,1'b0))fail_operation(E_VERIFY,SAVE_VERIFY_ERROR);
            else if(byte_index==63)goto_gap(S_WREN_C);else byte_index<=byte_index+1'b1;
          end
          S_WREN_C:if(!byte_busy&&!byte_start)start_byte(8'h06);else if(byte_done)goto_gap(S_COMMIT_CMD);
          S_COMMIT_CMD:if(!address_allowed(work_addr))fail_operation(E_FIREWALL,SAVE_FLASH_ERROR);else if(!byte_busy&&!byte_start)start_byte(8'h02);else if(byte_done)begin addr_index<=0;state<=S_COMMIT_ADDR;end
          S_COMMIT_ADDR:if(!byte_busy&&!byte_start)start_byte(commit_addr[23-addr_index*8 -:8]);else if(byte_done)begin if(addr_index==2)begin byte_index<=24;state<=S_COMMIT_DATA;end else addr_index<=addr_index+1'b1;end
          S_COMMIT_DATA:if(!byte_busy&&!byte_start)start_byte(record_byte(pending_config,pending_sequence,pending_pcrc,pending_hcrc,byte_index,1'b1));else if(byte_done)begin
            if(byte_index==27)begin return_after_poll<=S_FINAL_CMD;goto_gap(S_POLL_CMD);end else byte_index<=byte_index+1'b1;
          end
          S_FINAL_CMD:if(!byte_busy&&!byte_start)start_byte(8'h03);else if(byte_done)begin addr_index<=0;state<=S_FINAL_ADDR;end
          S_FINAL_ADDR:if(!byte_busy&&!byte_start)start_byte(work_addr[23-addr_index*8 -:8]);else if(byte_done)begin if(addr_index==2)begin byte_index<=0;verify_record<={512{1'b1}};state<=S_FINAL_DATA;end else addr_index<=addr_index+1'b1;end
          S_FINAL_DATA:if(!byte_busy&&!byte_start)start_byte(8'hff);else if(byte_done)begin
            verify_record[511-byte_index*8 -:8]<=rx_byte;
            if(byte_index==63)begin cs_active<=0;state<=S_FINISH;end else byte_index<=byte_index+1'b1;
          end
          S_FINISH:begin
            if(record_valid(verify_record))begin active_config<=pending_config;active_sequence<=pending_sequence;active_copy<=(work_addr==PARAM_A_ADDR)?1:2;config_from_flash<=1;save_status<=SAVE_OK;end
            else begin flash_error<=1;flash_error_code<=E_VERIFY;save_status<=SAVE_VERIFY_ERROR;end
            save_done<=1;state<=S_IDLE;
          end
          S_FAIL:begin save_done<=op_is_save;boot_done<=!op_is_save;active_config<=op_is_save?active_config:DEFAULT_CONFIG;state<=S_IDLE;end
          S_GAP:begin cs_active<=1;state<=gap_next;end
          default:state<=S_EOS;
        endcase
      end
    end
endmodule

`default_nettype wire
