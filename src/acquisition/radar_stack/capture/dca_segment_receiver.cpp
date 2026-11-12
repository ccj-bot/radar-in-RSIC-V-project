// Bounded DCA1000 UDP receiver. It never creates zero-filled ADC data.
// The production path is allocation-free after startup: a fixed packet ring and
// a fixed byte-count reorder window preserve bounded latency under load.
#include <arpa/inet.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <ctime>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace fs = std::filesystem;
constexpr size_t kPacketBytes = 1466, kHeaderBytes = 10, kPayloadBytes = 1456;
constexpr size_t kReceiveBufferBytes = 65536; // rejects any non-DCA-size UDP datagram without truncation.
std::atomic<bool> g_stop_requested{false}, g_hard_stop{false}, g_disk_stop{false};
void on_signal(int) { g_stop_requested.store(true); }

struct Args {
  std::string bind_ip, source_ip, session, boundary_ready_file;
  uint16_t port{}, source_port{};
  uint64_t chirp_bytes{}, segment_bytes{}, max_bytes{}, reserve_bytes{}, disk_guard_bytes{}, idle_timeout_ms{};
  size_t queue_capacity{262144}, reorder_window{64}, evidence_packets{4096};
  bool discover_source_port{false}, boundary_stop_on_signal{true};
};
struct Packet { uint32_t seq{}; uint64_t count{}, received_unix_ns{}, received_monotonic_ns{}; std::array<uint8_t,kPayloadBytes> payload{}; };
struct Stats {
  std::atomic<uint64_t> received{0}, written_packets{0}, written_bytes{0}, skipped_prefix_bytes{0};
  std::atomic<uint64_t> boundary_discard_packets{0}, boundary_discard_bytes{0};
  std::atomic<uint64_t> duplicate{0}, out_of_order{0}, short_packet{0}, oversized_packet{0};
  std::atomic<uint64_t> bad_source_ip{0}, bad_source_port{0}, byte_gap{0}, byte_stride_mismatch{0}, seq_mismatch{0};
  std::atomic<uint64_t> queue_overflow{0}, queue_peak{0}, trailing_unresolved{0};
  std::atomic<uint64_t> observed_source_port{0}, first_byte_count{0}, last_byte_end{0};
  std::atomic<bool> stream_data_seen{false};
  std::atomic<bool> fatal{false}; std::mutex error_mutex; std::string error;
  void fail(const std::string& why) { bool expected=false; if(fatal.compare_exchange_strong(expected,true)){std::lock_guard<std::mutex> lk(error_mutex);error=why;} }
  std::string error_copy() const { std::lock_guard<std::mutex> lk(const_cast<Stats*>(this)->error_mutex); return error; }
};

class FixedPacketRing {
 public:
  explicit FixedPacketRing(size_t capacity):slots_(capacity){if(!capacity)throw std::runtime_error("queue capacity must be positive");}
  bool full()const{return size_==slots_.size();} bool empty()const{return size_==0;} size_t size()const{return size_;}
  void push(Packet&& p){slots_[tail_]=std::move(p);tail_=(tail_+1)%slots_.size();++size_;}
  Packet pop(){Packet p=std::move(slots_[head_]);head_=(head_+1)%slots_.size();--size_;return p;}
 private: std::vector<Packet> slots_; size_t head_{0},tail_{0},size_{0};
};

struct ReorderSlot { bool present{false}; uint64_t count{}; Packet packet{}; };
// Slots are positions relative to the next expected byte_count. A packet farther
// away than the declared reorder window is a proven gap, not an allocation cue.
class FixedReorderWindow {
 public:
  explicit FixedReorderWindow(size_t capacity):slots_(capacity){if(!capacity)throw std::runtime_error("reorder window must be positive");}
  enum class Insert { inserted, duplicate, invalid };
  Insert insert(Packet&& p,uint64_t expected,std::string& reason) {
    const uint64_t delta=p.count-expected;
    if(delta%kPayloadBytes){reason="byte_count stride is not one payload";return Insert::invalid;}
    const uint64_t offset=delta/kPayloadBytes;
    if(offset>=slots_.size()){reason="byte_count gap exceeded fixed reorder window";return Insert::invalid;}
    ReorderSlot& slot=slots_[(base_+offset)%slots_.size()];
    if(slot.present){ if(slot.count==p.count)return Insert::duplicate; reason="fixed reorder slot collision";return Insert::invalid; }
    slot.packet=std::move(p);slot.count=slot.packet.count;slot.present=true;++size_;return Insert::inserted;
  }
  std::optional<Packet> take_expected(uint64_t expected) {
    ReorderSlot& slot=slots_[base_]; if(!slot.present)return std::nullopt;
    if(slot.count!=expected)throw std::runtime_error("fixed reorder window internal count mismatch");
    Packet p=std::move(slot.packet);slot.present=false;--size_;base_=(base_+1)%slots_.size();return p;
  }
  size_t size()const{return size_;}
 private: std::vector<ReorderSlot> slots_;size_t base_{0},size_{0};
};

struct SegmentStats {
  uint64_t bytes{},packets{},first_seq{},last_seq{},first_count{},last_count{},first_receive_ns{},last_receive_ns{},first_receive_monotonic_ns{},last_receive_monotonic_ns{};bool has_packet{false};
  void add_packet(const Packet&p){if(!has_packet){first_seq=p.seq;first_count=p.count;first_receive_ns=p.received_unix_ns;first_receive_monotonic_ns=p.received_monotonic_ns;has_packet=true;}last_seq=p.seq;last_count=p.count;last_receive_ns=p.received_unix_ns;last_receive_monotonic_ns=p.received_monotonic_ns;++packets;}
};

uint64_t read_u48(const uint8_t*p){uint64_t v=0;for(int i=5;i>=0;--i)v=(v<<8)|p[i];return v;}
uint32_t read_u32le(const uint8_t*p){return uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
uint64_t align_up(uint64_t v,uint64_t a){return ((v+a-1)/a)*a;}
void update_peak(std::atomic<uint64_t>&peak,uint64_t value){uint64_t old=peak.load();while(old<value&&!peak.compare_exchange_weak(old,value)){} }
std::string utc_iso8601(uint64_t unix_ns){if(!unix_ns)return "";const time_t seconds=time_t(unix_ns/1000000000ULL);tm utc{};gmtime_r(&seconds,&utc);char text[40]{};std::strftime(text,sizeof(text),"%Y-%m-%dT%H:%M:%S",&utc);char result[50]{};std::snprintf(result,sizeof(result),"%s.%03lluZ",text,(unsigned long long)((unix_ns/1000000ULL)%1000ULL));return result;}

Args parse(int argc,char**argv){
  Args a;for(int i=1;i<argc;i++){std::string k=argv[i];if(i+1>=argc)throw std::runtime_error("missing value for "+k);std::string v=argv[++i];
    if(k=="--bind-ip")a.bind_ip=v;else if(k=="--source-ip")a.source_ip=v;else if(k=="--port")a.port=uint16_t(std::stoul(v));else if(k=="--source-port")a.source_port=uint16_t(std::stoul(v));
    else if(k=="--session")a.session=v;else if(k=="--chirp-bytes")a.chirp_bytes=std::stoull(v);else if(k=="--segment-bytes")a.segment_bytes=std::stoull(v);else if(k=="--max-bytes")a.max_bytes=std::stoull(v);else if(k=="--reserve-bytes")a.reserve_bytes=std::stoull(v);else if(k=="--disk-guard-bytes")a.disk_guard_bytes=std::stoull(v);else if(k=="--idle-timeout-ms")a.idle_timeout_ms=std::stoull(v);
    else if(k=="--queue-packets")a.queue_capacity=std::stoull(v);else if(k=="--reorder-window")a.reorder_window=std::stoull(v);else if(k=="--evidence-packets")a.evidence_packets=std::stoull(v);else if(k=="--discover-source-port")a.discover_source_port=(v=="1");else if(k=="--boundary-stop-on-signal")a.boundary_stop_on_signal=(v=="1");else if(k=="--boundary-ready-file")a.boundary_ready_file=v;else throw std::runtime_error("unknown option "+k);}
  if(a.bind_ip.empty()||a.source_ip.empty()||a.session.empty()||!a.port||(!a.source_port&&!a.discover_source_port)||!a.chirp_bytes||!a.segment_bytes||!a.max_bytes)
    throw std::runtime_error("required: --bind-ip --source-ip --port --source-port (or --discover-source-port 1) --session --chirp-bytes --segment-bytes --max-bytes");
  if(a.segment_bytes%a.chirp_bytes||a.max_bytes<a.segment_bytes||a.max_bytes%a.segment_bytes)throw std::runtime_error("segment/max geometry invalid: all stops must end on complete physical segment boundaries");
 return a;
}

void publish_boundary_ready(const Args&a,uint64_t written,uint64_t segments){
 if(a.boundary_ready_file.empty())return;
 const fs::path destination(a.boundary_ready_file),temporary(destination.string()+".part");
 fs::create_directories(destination.parent_path());
 {std::ofstream o(temporary);if(!o)throw std::runtime_error("failed to create boundary-ready marker");o<<"{\n  \"status\": \"complete_segment_closed\",\n  \"written_bytes\": "<<written<<",\n  \"complete_segments\": "<<segments<<",\n  \"stop_reason\": \""<<(g_disk_stop.load()?"disk_reserve":"manual")<<"\"\n}\n";if(!o)throw std::runtime_error("failed to write boundary-ready marker");}
 fs::rename(temporary,destination);
}

void json_stats(const fs::path&p,const Stats&s,const Args&a,const std::string&status,int requested_rcv,int reported_rcv){
 const fs::path tmp(p.string()+".part");std::ofstream o(tmp);o<<"{\n  \"status\": \""<<status<<"\",\n"
 <<"  \"updated_unix_ms\": "<<std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count()<<",\n"
 <<"  \"complete_segments\": "<<s.written_bytes.load()/a.segment_bytes<<",\n"
 <<"  \"received_packets\": "<<s.received.load()<<",\n  \"written_packets\": "<<s.written_packets.load()<<",\n  \"written_bytes\": "<<s.written_bytes.load()<<",\n  \"skipped_prefix_bytes\": "<<s.skipped_prefix_bytes.load()<<",\n  \"boundary_discard_packets\": "<<s.boundary_discard_packets.load()<<",\n  \"boundary_discard_bytes\": "<<s.boundary_discard_bytes.load()<<",\n"
 <<"  \"duplicate_packets\": "<<s.duplicate.load()<<",\n  \"out_of_order_packets\": "<<s.out_of_order.load()<<",\n  \"short_packets\": "<<s.short_packet.load()<<",\n  \"oversized_packets\": "<<s.oversized_packet.load()<<",\n"
 <<"  \"source_ip_anomalies\": "<<s.bad_source_ip.load()<<",\n  \"source_port_anomalies\": "<<s.bad_source_port.load()<<",\n  \"byte_gaps\": "<<s.byte_gap.load()<<",\n  \"byte_stride_mismatches\": "<<s.byte_stride_mismatch.load()<<",\n  \"sequence_mismatches\": "<<s.seq_mismatch.load()<<",\n"
 <<"  \"queue_overflows\": "<<s.queue_overflow.load()<<",\n  \"queue_peak_packets\": "<<s.queue_peak.load()<<",\n  \"trailing_unresolved_packets\": "<<s.trailing_unresolved.load()<<",\n"
 <<"  \"chirp_bytes\": "<<a.chirp_bytes<<",\n  \"segment_bytes\": "<<a.segment_bytes<<",\n  \"max_bytes\": "<<a.max_bytes<<",\n  \"expected_source_ip\": \""<<a.source_ip<<"\",\n  \"expected_source_port\": "<<(a.source_port?std::to_string(a.source_port):"null")<<",\n  \"source_port_discovery_mode\": "<<(a.discover_source_port?"true":"false")<<",\n  \"observed_source_port\": "<<(s.observed_source_port.load()?std::to_string(s.observed_source_port.load()):"null")<<",\n  \"first_byte_count\": "<<s.first_byte_count.load()<<",\n  \"last_byte_end\": "<<s.last_byte_end.load()<<",\n"
 <<"  \"socket_rcvbuf_requested_bytes\": "<<requested_rcv<<",\n  \"socket_rcvbuf_reported_bytes\": "<<reported_rcv<<",\n  \"header_evidence_packets_requested\": "<<a.evidence_packets<<",\n  \"error\": \""<<s.error_copy()<<"\"\n}\n";o.close();if(!o)throw std::runtime_error("failed to publish receiver status");fs::rename(tmp,p);
}

int main(int argc,char**argv){try{
 Args a=parse(argc,argv);std::signal(SIGINT,on_signal);std::signal(SIGTERM,on_signal);
 fs::path radar=fs::path(a.session)/"radar",segments=radar/"raw_segments";fs::create_directories(segments);
 std::ofstream interval_csv(radar/"radar_packet_intervals.csv");interval_csv<<"interval_start_unix_ms,received_packets,written_packets,written_bytes,queue_peak_packets,duplicate_packets,out_of_order_packets,byte_gaps,sequence_mismatches\n";
 std::ofstream anomaly_csv(radar/"radar_anomalies.csv");anomaly_csv<<"event,seq,byte_count,source_ip,source_port,recv_bytes\n";
 std::mutex anomaly_mutex;auto log_anomaly=[&](const char*event,uint32_t seq,uint64_t count,const std::string&ip,uint16_t port,int bytes){std::lock_guard<std::mutex>lk(anomaly_mutex);anomaly_csv<<event<<","<<seq<<","<<count<<","<<ip<<","<<port<<","<<bytes<<"\n";};
 std::ofstream header_evidence(radar/"dca_packet_headers_sample.bin",std::ios::binary);std::ofstream header_index(radar/"dca_packet_headers_sample.csv");header_index<<"sample_index,receive_unix_ns,receive_utc,sequence,byte_count,source_ip,source_port\n";
 std::ofstream segment_csv(radar/"radar_segments.csv");segment_csv<<"segment_index,pulse_start,pulse_end,expected_bytes,actual_bytes,packet_count,first_receive_unix_ns,last_receive_unix_ns,first_receive_utc,last_receive_utc,first_sequence,last_sequence,first_byte_count,last_byte_count,quality_status,first_receive_monotonic_ns,last_receive_monotonic_ns\n";
 int fd=socket(AF_INET,SOCK_DGRAM,0);if(fd<0)throw std::runtime_error("socket failed");int requested_rcv=268435456,reported_rcv=0;setsockopt(fd,SOL_SOCKET,SO_RCVBUF,&requested_rcv,sizeof(requested_rcv));socklen_t ol=sizeof(reported_rcv);getsockopt(fd,SOL_SOCKET,SO_RCVBUF,&reported_rcv,&ol);timeval tv{0,200000};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));
 sockaddr_in local{};local.sin_family=AF_INET;local.sin_port=htons(a.port);if(inet_pton(AF_INET,a.bind_ip.c_str(),&local.sin_addr)!=1||bind(fd,(sockaddr*)&local,sizeof(local))!=0)throw std::runtime_error("bind failed");
 std::mutex m;std::condition_variable cv;FixedPacketRing q(a.queue_capacity);Stats s;std::atomic<bool>reader_done{false};
 std::thread reader([&]{std::array<uint8_t,kReceiveBufferBytes>raw{};size_t headers_written=0;auto last_packet=std::chrono::steady_clock::now();while(!g_hard_stop.load()&&!s.fatal.load()){
   sockaddr_in src{};socklen_t sl=sizeof(src);int n=recvfrom(fd,raw.data(),raw.size(),0,(sockaddr*)&src,&sl);if(n<0){if(a.idle_timeout_ms&&!g_stop_requested.load()&&std::chrono::steady_clock::now()-last_packet>=std::chrono::milliseconds(a.idle_timeout_ms)){s.fail("ADC stream timeout");break;}if(g_stop_requested.load()&&std::chrono::steady_clock::now()-last_packet>=std::chrono::milliseconds(600))break;continue;}last_packet=std::chrono::steady_clock::now();char ipbuf[INET_ADDRSTRLEN]{};inet_ntop(AF_INET,&src.sin_addr,ipbuf,sizeof(ipbuf));std::string ip(ipbuf);uint16_t source_port=ntohs(src.sin_port);
   if(a.source_ip!=ip){s.bad_source_ip++;log_anomaly("bad_source_ip",0,0,ip,source_port,n);s.fail("unexpected UDP source IP");break;}
   if(a.discover_source_port){const uint64_t observed=s.observed_source_port.load();if(!observed)s.observed_source_port.store(source_port);else if(observed!=source_port){s.bad_source_port++;log_anomaly("source_port_changed",0,0,ip,source_port,n);s.fail("ADC data source port changed during discovery");break;}}else if(a.source_port!=source_port){s.bad_source_port++;log_anomaly("bad_source_port",0,0,ip,source_port,n);s.fail("unexpected UDP source port");break;}
   if(n!=int(kPacketBytes)){if(n>int(kPacketBytes))s.oversized_packet++;else s.short_packet++;log_anomaly(n>int(kPacketBytes)?"oversized_packet":"short_packet",0,0,ip,source_port,n);s.fail("UDP datagram length differs from DCA packet size");break;}
   const uint64_t received_unix_ns=uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
   if(headers_written<a.evidence_packets){header_evidence.write(reinterpret_cast<const char*>(raw.data()),kHeaderBytes);header_index<<headers_written<<","<<received_unix_ns<<","<<utc_iso8601(received_unix_ns)<<","<<read_u32le(raw.data())<<","<<read_u48(raw.data()+4)<<","<<ip<<","<<source_port<<"\n";if(!header_evidence||!header_index){s.fail("failed to write packet-header evidence");break;}++headers_written;}
   Packet p;p.seq=read_u32le(raw.data());p.count=read_u48(raw.data()+4);p.received_unix_ns=received_unix_ns;p.received_monotonic_ns=uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());std::memcpy(p.payload.data(),raw.data()+kHeaderBytes,kPayloadBytes);
   {std::lock_guard<std::mutex>lk(m);if(q.full()){s.queue_overflow++;s.fail("fixed packet ring overflow");break;}q.push(std::move(p));s.received++;update_peak(s.queue_peak,q.size());}cv.notify_one();
 }reader_done.store(true);cv.notify_all();});

 FixedReorderWindow reorder(a.reorder_window);std::optional<uint64_t>expected,previous_seq;uint64_t capture_start=0,capture_written=0,segment_written=0,segment_index=0;bool capacity_complete=false,manual_boundary_complete=false;std::ofstream out;fs::path part;SegmentStats segment;
 auto close_segment=[&](bool complete,const char*requested_quality)->bool{if(!out.is_open())return true;out.flush();bool io_ok=out.good();out.close();io_ok=io_ok&&!out.fail();std::string quality=io_ok?requested_quality:"write_failed_part";if(complete&&io_ok){try{fs::rename(part,part.string().substr(0,part.string().size()-5));}catch(const std::exception&exc){io_ok=false;quality="rename_failed_part";s.fail(std::string("segment rename failed: ")+exc.what());}}
   const uint64_t pulse_start=segment_index*(a.segment_bytes/a.chirp_bytes),pulse_end=pulse_start+(a.segment_bytes/a.chirp_bytes)-1;segment_csv<<segment_index<<","<<pulse_start<<","<<pulse_end<<","<<a.segment_bytes<<","<<segment_written<<","<<segment.packets<<",";if(segment.has_packet)segment_csv<<segment.first_receive_ns<<","<<segment.last_receive_ns<<","<<utc_iso8601(segment.first_receive_ns)<<","<<utc_iso8601(segment.last_receive_ns)<<","<<segment.first_seq<<","<<segment.last_seq<<","<<segment.first_count<<","<<segment.last_count;else segment_csv<<"0,0,,,0,0,0,0";segment_csv<<","<<quality<<","<<segment.first_receive_monotonic_ns<<","<<segment.last_receive_monotonic_ns<<"\n";segment_csv.flush();if(!segment_csv){s.fail("failed to write segment manifest");io_ok=false;}if(!io_ok)s.fail("segment flush/close failed; .part retained");return io_ok;};
 auto open_segment=[&]{if(a.reserve_bytes&&fs::space(segments).available<a.reserve_bytes+a.segment_bytes){s.fail("disk reserve reached before new segment");return;}part=segments/("segment_"+std::to_string(segment_index)+".bin.part");out.open(part,std::ios::binary);if(!out)throw std::runtime_error("failed to open segment output");segment_written=0;segment=SegmentStats{};};
 auto interval_start=std::chrono::steady_clock::now();auto interval_epoch=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();uint64_t lr=0,lwp=0,lwb=0,ld=0,lo=0,lg=0,ls=0;
 auto flush_interval=[&](bool force){auto now=std::chrono::steady_clock::now();if(!force&&now-interval_start<std::chrono::seconds(1))return;if(a.reserve_bytes&&fs::space(segments).available<=a.reserve_bytes+a.disk_guard_bytes){g_disk_stop.store(true);g_stop_requested.store(true);}json_stats(radar/"receiver_live.json",s,a,"receiving",requested_rcv,reported_rcv);uint64_t r=s.received.load(),wp=s.written_packets.load(),wb=s.written_bytes.load(),d=s.duplicate.load(),oo=s.out_of_order.load(),g=s.byte_gap.load(),sm=s.seq_mismatch.load();interval_csv<<interval_epoch<<","<<r-lr<<","<<wp-lwp<<","<<wb-lwb<<","<<s.queue_peak.load()<<","<<d-ld<<","<<oo-lo<<","<<g-lg<<","<<sm-ls<<"\n";interval_csv.flush();if(!interval_csv)s.fail("failed to flush packet interval evidence");lr=r;lwp=wp;lwb=wb;ld=d;lo=oo;lg=g;ls=sm;interval_start=now;interval_epoch=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();};
 while(!s.fatal.load()&&!capacity_complete&&!manual_boundary_complete){Packet p;bool got=false;{std::unique_lock<std::mutex>lk(m);cv.wait_for(lk,std::chrono::milliseconds(200),[&]{return !q.empty()||reader_done.load()||s.fatal.load();});if(!q.empty()){p=q.pop();got=true;}}flush_interval(false);
   if(!got){bool input_finished=false;{std::lock_guard<std::mutex>lk(m);input_finished=reader_done.load()&&q.empty();}if(input_finished&&reorder.size()){s.trailing_unresolved+=reorder.size();s.byte_gap++;s.fail("trailing byte_count gap at capture stop");break;}if(input_finished)break;continue;}
   if(!expected){expected=p.count;capture_start=align_up(p.count,a.segment_bytes);s.skipped_prefix_bytes=capture_start-p.count;}
   if(p.count<*expected){s.duplicate++;log_anomaly("duplicate",p.seq,p.count,"",0,kPacketBytes);continue;}if(p.count>*expected)s.out_of_order++;
   std::string reason;auto inserted=reorder.insert(std::move(p),*expected,reason);if(inserted==FixedReorderWindow::Insert::duplicate){s.duplicate++;continue;}if(inserted==FixedReorderWindow::Insert::invalid){if(reason.find("stride")!=std::string::npos)s.byte_stride_mismatch++;else s.byte_gap++;s.fail(reason);break;}
   while(!s.fatal.load()&&!capacity_complete&&!manual_boundary_complete){auto current=reorder.take_expected(*expected);if(!current)break;Packet cur=std::move(*current);if(previous_seq&&cur.seq!=uint32_t(*previous_seq+1)){s.seq_mismatch++;log_anomaly("sequence_mismatch",cur.seq,cur.count,"",0,kPacketBytes);s.fail("sequence mismatch against byte_count stream");break;}previous_seq=cur.seq;uint64_t start=cur.count,end=cur.count+kPayloadBytes,pos=std::max(start,capture_start);bool contributed=false;
     while(pos<end&&capture_written<a.max_bytes&&!s.fatal.load()){
       if(!out.is_open())open_segment();if(s.fatal.load())break;
       if(!segment.has_packet||segment.last_count!=cur.count)segment.add_packet(cur);
       contributed=true;
       uint64_t take=std::min<uint64_t>({end-pos,a.segment_bytes-segment_written,a.max_bytes-capture_written});
       out.write(reinterpret_cast<const char*>(cur.payload.data()+(pos-start)),take);
       if(!out){s.fail("segment write failed");break;}
       pos+=take;segment_written+=take;capture_written+=take;s.written_bytes+=take;
       if(segment_written==a.segment_bytes){
         if(!close_segment(true,"ok"))break;
         ++segment_index;
         if(capture_written==a.max_bytes){capacity_complete=true;g_hard_stop.store(true);break;}
         if(g_stop_requested.load()&&a.boundary_stop_on_signal){
           if(pos<end){s.boundary_discard_packets++;s.boundary_discard_bytes+=end-pos;}
           manual_boundary_complete=true;
           publish_boundary_ready(a,capture_written,segment_index);
           if(a.boundary_ready_file.empty())g_hard_stop.store(true);
           break;
         }
       }
     }
     if(!s.stream_data_seen.exchange(true))s.first_byte_count=cur.count;
     s.last_byte_end=end;
     if(contributed)s.written_packets++;
     *expected=end;
   }
 }
 if(manual_boundary_complete&&!a.boundary_ready_file.empty()){
   while(!g_hard_stop.load()&&!s.fatal.load()){
     bool discarded=false;
     {std::unique_lock<std::mutex>lk(m);cv.wait_for(lk,std::chrono::milliseconds(50),[&]{return !q.empty()||reader_done.load()||g_hard_stop.load()||s.fatal.load();});if(!q.empty()){q.pop();discarded=true;}}
     if(discarded){s.boundary_discard_packets++;s.boundary_discard_bytes+=kPayloadBytes;}
     else if(reader_done.load())break;
   }
 }
 if(out.is_open())close_segment(false,s.fatal.load()?"incomplete_failed":"incomplete_manual_stop");
 reader.join();
 if(manual_boundary_complete){size_t queued=0;{std::lock_guard<std::mutex>lk(m);queued=q.size();}const size_t buffered_packets=queued+reorder.size();s.boundary_discard_packets+=buffered_packets;s.boundary_discard_bytes+=uint64_t(buffered_packets)*kPayloadBytes;}
 close(fd);flush_interval(true);interval_csv.flush();anomaly_csv.flush();segment_csv.flush();header_evidence.flush();header_index.flush();
 const std::string status=s.fatal.load()?"failed":(capacity_complete?"capacity_stop":(manual_boundary_complete?(g_disk_stop.load()?"disk_reserve_stop":"manual_boundary_stop"):"manual_stop"));json_stats(radar/"radar_quality_summary.json",s,a,status,requested_rcv,reported_rcv);json_stats(radar/"receiver_live.json",s,a,status,requested_rcv,reported_rcv);return s.fatal.load()?2:0;
}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 2;}}
