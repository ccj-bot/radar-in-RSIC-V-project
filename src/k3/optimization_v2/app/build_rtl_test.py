from pathlib import Path
import random,json
W=Path(__file__).resolve().parent;rng=random.Random(20261108)
NA=512;VQ=48;SCALE=26564;frames=[]
for f in range(2):
 records=[]
 for i in range(96):
  sine=rng.randint(-110000,110000);ar=rng.randrange(1000);tr=rng.randrange(65536);valid=(i%13!=0)
  product=sine*VQ*SCALE;floor=product//(1<<31);fraction=product-floor*(1<<31);q=NA//2+floor;tq=min(65536,(fraction+16384)>>15)
  if valid and 0<=q<NA-1:
   products=[(65536-tq)*(65536-tr),(65536-tq)*tr,tq*(65536-tr),tq*tr]
   weights=[min(1023,(v+2097152)>>22) for v in products]
   expected=(q<<50)|(ar<<40)|(weights[0]<<30)|(weights[1]<<20)|(weights[2]<<10)|weights[3]
  else:expected=0
  word=(int(valid)<<63)|((sine&((1<<18)-1))<<45)|(ar<<35)|(tr<<19)
  records.append((word,expected))
 frames.append(records)
expected=[v for frame in frames for _,v in frame]
def array_assign(name,values):return '\n'.join(f"{name}[{i}]=64'h{v:016x};" for i,v in enumerate(values))
body=[]
for frame in frames:
 header=(0x504c<<48)|(1<<44)|(VQ<<35)|(len(frame)<<15)
 body.append(f"send(64'h{header:016x},0);")
 for i,(v,_) in enumerate(frame):body.append(f"send(64'h{v:016x},{1 if i==len(frame)-1 else 0});")
 body.append('wait(seen=='+str((len(body)//100+1)*96)+');') if False else None
 body.append('repeat(12) @(posedge clk);')
tb='''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0;reg[63:0] sdata=0;reg sv=0;wire sr;reg sl=0;wire[63:0] md;wire mv,ml;reg mr=0;wire err;wire[8:0] active;
reg[63:0] expected[0:191];integer seen=0;integer cycles=0;
sar_pl_iw_generator #(.NA(512),.Q_SCALE_PER_VQ4_Q14(26564)) dut(.clk(clk),.rst_n(rst_n),.s_axis_tdata(sdata),.s_axis_tvalid(sv),.s_axis_tready(sr),.s_axis_tlast(sl),.s_axis_tkeep(8'hff),.s_axis_tuser(1'b0),.m_axis_tdata(md),.m_axis_tvalid(mv),.m_axis_tready(mr),.m_axis_tlast(ml),.m_axis_tkeep(),.m_axis_tuser(),.cfg_error(err),.active_v_q4(active));
always @(negedge clk) begin cycles=cycles+1;mr=(cycles%7!=0 && cycles%11!=0);end
always @(posedge clk) if(rst_n&&mv&&mr) begin
 if(md!==expected[seen]) begin $display("FAIL index=%0d got=%h expected=%h",seen,md,expected[seen]);$fatal;end
 if(ml!==((seen%96)==95))begin $display("FAIL last index=%0d",seen);$fatal;end
 seen=seen+1;
end
task send(input[63:0] data,input last);begin
 @(negedge clk);sdata=data;sl=last;sv=1;
 @(posedge clk);while(!sr)@(posedge clk);
 @(negedge clk);sv=0;sl=0;
end endtask
initial begin
EXPECTED
repeat(4)@(negedge clk);rst_n=1;
BODY
wait(seen==192);repeat(5)@(posedge clk);if(err||active!=48)$fatal;
$display("PASS 192 descriptors, 2 frames, random geometry and deterministic backpressure");$finish;
end
initial begin #200000;$display("FAIL timeout seen=%0d",seen);$fatal;end
endmodule
'''.replace('EXPECTED',array_assign('expected',expected)).replace('BODY','\n'.join(body))
(W/'tb_descriptor.v').write_text(tb,encoding='utf8')
(W/'rtl_reference_vectors.json').write_text(json.dumps({'seed':20261108,'frames':2,'pixels_per_frame':96,'backpressure':'ready suppressed every 7th and 11th cycle','expected':expected},indent=2))
print('Wrote descriptor regression with 192 vectors')
