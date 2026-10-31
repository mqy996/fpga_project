#define _WIN32_WINNT 0x0601
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdint>
#include <iostream>
#include <iomanip>
#include <string>
#include <vector>
#include <chrono>
#include <stdexcept>
#pragma comment(lib,"ws2_32.lib")

static constexpr uint16_t CTRL_PORT=56556;
static void p32(std::vector<uint8_t>&b,uint32_t v){b.push_back(v>>24);b.push_back(v>>16);b.push_back(v>>8);b.push_back(v);}
static void p16(std::vector<uint8_t>&b,uint16_t v){b.push_back(v>>8);b.push_back(v);}
static uint32_t g32(const uint8_t*p){return(uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|p[3];}
static uint16_t g16(const uint8_t*p){return(uint16_t(p[0])<<8)|p[1];}
static uint32_t ipval(const std::string&s){in_addr a{};if(inet_pton(AF_INET,s.c_str(),&a)!=1)throw std::runtime_error("invalid IPv4: "+s);return ntohl(a.s_addr);}
static std::string ipstr(uint32_t v){in_addr a{};a.s_addr=htonl(v);char s[INET_ADDRSTRLEN]{};inet_ntop(AF_INET,&a,s,sizeof s);return s;}
static const char* status_name(uint32_t s){static const char*n[]={"OK","INVALID_CMD","INVALID_LENGTH","INVALID_PARAM","INVALID_STATE","BUSY","UNSUPPORTED","FLASH_ERROR","VERIFY_ERROR","TIMEOUT"};return s<10?n[s]:"UNKNOWN";}
static std::vector<uint8_t> packet(uint32_t cmd,uint32_t tid,const std::vector<uint8_t>&d){std::vector<uint8_t>b;p32(b,cmd);p32(b,0);p32(b,(uint32_t)d.size());p32(b,tid);b.insert(b.end(),d.begin(),d.end());return b;}
static void print_config(const uint8_t*p,size_t n){if(n<28)return;std::cout<<"local_ip="<<ipstr(g32(p))<<" netmask="<<ipstr(g32(p+4))<<" target_ip="<<ipstr(g32(p+8))<<" data_port="<<g16(p+12)<<" sample_rate="<<g32(p+16)<<" channel_mask=0x"<<std::hex<<std::setw(8)<<std::setfill('0')<<g32(p+20)<<std::dec<<" groups="<<g32(p+24);if(n>=40)std::cout<<" source="<<(g32(p+28)?"flash":"default/runtime")<<" flash_sequence="<<g32(p+32)<<" payload_bytes="<<g16(p+36);std::cout<<"\n";}
int main(int argc,char**argv){
 try{
  if(argc<2){std::cerr<<"usage: fpga_param_cli discover|info|get-config|set-config|start|stop|save|restore-default|flash-info|status [options]\n";return 2;}
  WSADATA w{};if(WSAStartup(MAKEWORD(2,2),&w))throw std::runtime_error("WSAStartup failed");
  std::string action=argv[1],device="192.168.0.2",bind_ip="0.0.0.0",broadcast="255.255.255.255";
  std::string local_ip="192.168.0.2",mask="255.255.255.0",target="192.168.0.3";uint16_t port=56555;uint32_t rate=500000,channels=0x00ffffff,groups=30;
  for(int i=2;i<argc;i++){std::string a=argv[i];auto value=[&](){if(++i>=argc)throw std::runtime_error("missing value for "+a);return std::string(argv[i]);};
   if(a=="--ip")device=value();else if(a=="--bind")bind_ip=value();else if(a=="--broadcast")broadcast=value();
   else if(a=="--local-ip")local_ip=value();else if(a=="--mask")mask=value();else if(a=="--target")target=value();
   else if(a=="--port")port=(uint16_t)std::stoul(value());else if(a=="--rate")rate=std::stoul(value());
   else if(a=="--channels")channels=std::stoul(value(),nullptr,0);else if(a=="--groups")groups=std::stoul(value());else throw std::runtime_error("unknown option: "+a);}
  uint32_t cmd=0;if(action=="discover")cmd=1;else if(action=="info")cmd=2;else if(action=="set-config")cmd=3;else if(action=="start")cmd=4;else if(action=="stop")cmd=5;else if(action=="status")cmd=6;else if(action=="get-config")cmd=7;else if(action=="save")cmd=8;else if(action=="restore-default")cmd=9;else if(action=="flash-info")cmd=10;else throw std::runtime_error("unknown action: "+action);
  std::vector<uint8_t>d;if(cmd==3){p32(d,ipval(local_ip));p32(d,ipval(mask));p32(d,ipval(target));p16(d,port);p16(d,0);p32(d,rate);p32(d,channels);p32(d,groups);}
  uint32_t tid=(uint32_t)std::chrono::high_resolution_clock::now().time_since_epoch().count();auto req=packet(cmd,tid,d);
  SOCKET s=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);if(s==INVALID_SOCKET)throw std::runtime_error("socket failed");
    BOOL yes=TRUE;setsockopt(s,SOL_SOCKET,SO_BROADCAST,(char*)&yes,sizeof yes);
    // SAVE includes a physical 4-KiB sector erase.  Do not mistake a slow
    // but valid W25Q128 operation for a lost UDP response.
    DWORD timeout=(action=="save")?10000:1200;
    setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,(char*)&timeout,sizeof timeout);
  sockaddr_in local{};local.sin_family=AF_INET;local.sin_port=0;if(inet_pton(AF_INET,bind_ip.c_str(),&local.sin_addr)!=1||bind(s,(sockaddr*)&local,sizeof local)==SOCKET_ERROR)throw std::runtime_error("bind failed; check --bind adapter address");
  sockaddr_in dst{};dst.sin_family=AF_INET;dst.sin_port=htons(CTRL_PORT);std::string to=(cmd==1)?broadcast:device;if(inet_pton(AF_INET,to.c_str(),&dst.sin_addr)!=1)throw std::runtime_error("invalid destination");
  std::vector<uint8_t>rsp; sockaddr_in from{};bool ok=false;uint8_t buf[1600];
  for(int attempt=0;attempt<4&&!ok;attempt++){
   if(sendto(s,(char*)req.data(),(int)req.size(),0,(sockaddr*)&dst,sizeof dst)==SOCKET_ERROR)throw std::runtime_error("sendto failed");
   int fl=sizeof from,n=recvfrom(s,(char*)buf,sizeof buf,0,(sockaddr*)&from,&fl);
   if(n>=16&&g32(buf)==(cmd|0x80000000u)&&g32(buf+12)==tid&&g32(buf+8)==uint32_t(n-16)){rsp.assign(buf,buf+n);ok=true;}
  }
  if(!ok){closesocket(s);WSACleanup();std::cerr<<"timeout: no valid response (for unknown IP use discover --bind <PC-IP> --broadcast <subnet-broadcast>)\n";return 1;}
  char froms[INET_ADDRSTRLEN]{};inet_ntop(AF_INET,&from.sin_addr,froms,sizeof froms);uint32_t st=g32(rsp.data()+4),len=g32(rsp.data()+8);const uint8_t*p=rsp.data()+16;
  std::cout<<"from="<<froms<<":"<<ntohs(from.sin_port)<<" status="<<st<<"("<<status_name(st)<<") tid="<<g32(rsp.data()+12)<<" bytes="<<len<<"\n";
  if(st==0){
   if(cmd==1&&len>=28)std::cout<<"device_id="<<g32(p)<<" firmware=0x"<<std::hex<<g32(p+4)<<" hardware=0x"<<g32(p+8)<<std::dec<<" state="<<g32(p+12)<<" local_ip="<<ipstr(g32(p+16))<<" netmask="<<ipstr(g32(p+20))<<" data_port="<<g16(p+24)<<" control_port="<<g16(p+26)<<"\n";
   else if((cmd==3||cmd==7||cmd==9)&&len>=28)print_config(p,len);
   else if(cmd==8&&len>=12)std::cout<<"flash_sequence="<<g32(p)<<" active_copy="<<g32(p+4)<<" flash_status=0x"<<std::hex<<g32(p+8)<<std::dec<<"\n";
   else if(cmd==10&&len>=24)std::cout<<"jedec=0x"<<std::hex<<g32(p)<<std::dec<<" active_copy="<<g32(p+4)<<" sequence="<<g32(p+8)<<" flash_error="<<g32(p+12)<<" error_code="<<g32(p+16)<<" busy="<<g32(p+20)<<"\n";
   else if(cmd==6&&len>=32)std::cout<<"state="<<g32(p)<<" packets="<<g32(p+4)<<" fifo="<<g32(p+8)<<" arp_valid="<<g32(p+12)<<" flash_busy="<<g32(p+16)<<" flash_error="<<g32(p+20)<<" flash_code="<<g32(p+24)<<" adc_error="<<g32(p+28)<<"\n";
  }
  closesocket(s);WSACleanup();return st==0?0:1;
 }catch(const std::exception&e){std::cerr<<"ERROR: "<<e.what()<<"\n";WSACleanup();return 2;}
}
