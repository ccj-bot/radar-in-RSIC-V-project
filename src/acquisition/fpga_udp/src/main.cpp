#include <pybind11/pybind11.h>
#include <pybind11/numpy.h>
#include <iostream>
#include <thread>
#include <future>
#include <mutex>
#include <cmath>
#include <chrono>
#include <fstream>
#include <cstdio>
#include <vector>
#ifdef _WIN32
    #include <Winsock2.h>
    #include <ws2tcpip.h>
    #pragma comment(lib, "Ws2_32.lib")
#elif __linux__
    #include <sys/socket.h>
    #include <netinet/in.h>
    #include <fcntl.h>
#endif
#include "WzSerialportPlus.h"
#include "mmw_example_nonos.h"
#include "unlock_queue.h"

extern int MMWL_SOPControl(unsigned char deviceMap, int SOPmode);

#ifdef __GNUC__
#define PACK( __Declaration__ ) __Declaration__ __attribute__((__packed__))
#endif

#ifdef _MSC_VER
#define PACK( __Declaration__ ) __pragma( pack(push, 1) ) __Declaration__ __pragma( pack(pop) )
#endif

#define STRINGIFY(x) #x
#define MACRO_STRINGIFY(x) STRINGIFY(x)

namespace py = pybind11;

WzSerialportPlus radar_serial_port;
int memidx=0;
int overflowCnt=0;
int packetSize_g=1466;
uint32_t packetNum_g=1000;
uint8_t *serial_buf_ptr=NULL;
std::mutex serial_buf_mutex;
std::mutex udp_mutex;
std::atomic<bool> udp_continue_g=true;
std::mutex udp_async_mutex;
std::future<pybind11::array_t<uint8_t>> udp_val;
uint32_t receivedPacketNum_g=0,firstPacketNum_g=0,lastPacketNum_g=0,expectedPacketNum_g=0;
#define packetSize_d 1466
PACK(typedef struct {
    uint32_t seqNum;
    uint8_t byteCnt[6];
    uint8_t payload[packetSize_d-10];
}) packet_t;
UnlockQueue<packet_t> *udp_queue_g;
std::thread udp_thread_g;

struct UdpFileStats {
    std::string outputPath;
    uint64_t rawBytesWritten = 0;
    uint64_t expectedRawBytes = 0;
    uint64_t copiedRawBytes = 0;
    uint32_t expectedPacketNum = 0;
    uint32_t receivedPacketNum = 0;
    uint32_t firstPacketNum = 0;
    uint32_t lastPacketNum = 0;
    uint32_t queueCapacityPackets = 0;
    uint32_t queuePeakPackets = 0;
    uint32_t shortPacketNum = 0;
    bool timedOut = false;
    bool sorted = true;
};

std::future<UdpFileStats> udp_file_val;
// py::array_t<uint8_t> doubleBuffer[2];
// bool firstBufFull=false;

int add(int i, int j) {
    return i+j;
}

bool radar_start_read_thread(std::string portName, int baudrate, uint32_t packetNum, int packetSize){
    if(serial_buf_ptr!=NULL)
        return false;
    serial_buf_ptr = new uint8_t[packetSize*packetNum];//initialize buffer
    packetNum_g=packetNum;
    packetSize_g=packetSize;

    radar_serial_port.setReceiveCalback([&](char* data,int length){//Set the receive callback function and execute it after receiving the data
        serial_buf_mutex.lock();//exclusive buffer
        if(memidx+length>packetSize_g*packetNum_g){//Guaranteed not to exceed the buffer range
            overflowCnt++;
            printf("[fpga_udp]serial buffer overflowed for %d time(s)!memidx=%d,length=%d,packetSize=%d,packetNum=%d\n",overflowCnt,memidx,length,packetSize_g,packetNum_g);
            memidx=0;
        }
        memcpy(serial_buf_ptr+memidx,data,length);//Copy the received data into the buffer
        memidx+=length;
        serial_buf_mutex.unlock();
    });

    #ifdef _WIN32
        if (portName.substr(0,3)=="COM" && stoi(portName.substr(3))>=10)
            portName="\\\\.\\"+portName;//port name has prefix in windows
    #endif
    return radar_serial_port.open(portName,baudrate,1,8,'n');//Open the port to start the thread to receive data
}

py::array_t<uint8_t> get_radar_buf(){
    serial_buf_mutex.lock();//exclusive buffer
    auto result = py::array_t<uint8_t>(memidx);
    py::buffer_info buf = result.request();
    uint8_t *buf_ptr = static_cast<uint8_t *>(buf.ptr);
    memcpy(buf_ptr,serial_buf_ptr,memidx);
    memidx=0;
    serial_buf_mutex.unlock();
    return result;
}

void radar_stop_read_thread(){
    radar_serial_port.close();
    serial_buf_mutex.lock();
    delete[] serial_buf_ptr;
    serial_buf_ptr=NULL;
    memidx=0;
    overflowCnt=0;
    serial_buf_mutex.unlock();
}

void _read_data_udp(int sock_fd, uint32_t frameNum, int bytesInFrame, int packetSize, int &lastFrameRemainBytes, int timeout_s, py::array_t<uint8_t> buf){
    udp_mutex.lock();

    if(packetSize%2 != 0){
        throw std::runtime_error("[fpga_udp]Number of packetSize must be even");
    }

    py::buffer_info buf_info = buf.request();
    uint8_t *buf_ptr = static_cast<uint8_t *>(buf_info.ptr);

    // Time out
    #ifdef __linux__
        int sockfd = sock_fd;
        struct timeval tv;
        tv.tv_sec  = timeout_s;
        tv.tv_usec = 0;
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(struct timeval));
    #elif _WIN32
        SOCKET sockfd = (SOCKET)sock_fd;
        int TimeOut = timeout_s*1000;
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&TimeOut, sizeof(TimeOut));
    #endif

    struct sockaddr_in src;
    socklen_t src_len = sizeof(src);
    memset(&src, 0, sizeof(src));

    uint32_t seqNum=0;
    uint64_t bytesCnt;
    int receivePacketLen=0,lastFrameTransferedBytes;

    // Wait for start of next frame
    do{
        receivePacketLen=recvfrom(sockfd, (char*)&buf_ptr[0], packetSize, 0, (sockaddr*)&src, &src_len);
        if (receivePacketLen < 0){      //blocking receive timeout
            printf("[fpga_udp]udp time out\n");
            udp_mutex.unlock();
            lastFrameRemainBytes=-1;
            return;
        }
        seqNum = *(uint32_t *)buf_ptr;//first 4 bytes: sequence number for every packet
        bytesCnt = (seqNum-1)*(packetSize-10);
        lastFrameTransferedBytes = bytesCnt % bytesInFrame;
        lastFrameRemainBytes = (bytesInFrame-lastFrameTransferedBytes) % bytesInFrame;
    }while(lastFrameRemainBytes>=packetSize-10);
    
    expectedPacketNum_g = ceil((lastFrameRemainBytes + frameNum*bytesInFrame)/((double)(packetSize-10)));

    // Read in the rest of the frame
    for(int i=1;i<expectedPacketNum_g;i++){
        int idx = i*packetSize;
        // if(idx>=packetSize*packetNum){
        //     throw std::runtime_error("Array Index Out Of Bounds!");
        // }
        receivePacketLen=recvfrom(sockfd, (char*)&buf_ptr[idx], packetSize, 0, (sockaddr*)&src, &src_len);
        if (receivePacketLen < 0){      //blocking receive timeout
            printf("[fpga_udp]udp time out\n");
            break;
        }
    }

    udp_mutex.unlock();
}

py::array_t<uint8_t> postProc_packet_sort(py::array_t<uint8_t> buf, uint32_t frameNum, int bytesInFrame, int packetSize, int lastFrameRemainBytes, uint32_t &receivedPacketNum, uint32_t &firstPacketNum, uint32_t &lastPacketNum){
    int payloadSize = packetSize-10, cpySize;
    uint32_t packetNum = ceil((lastFrameRemainBytes + frameNum*bytesInFrame)/((double)(packetSize-10)));
    uint32_t seqNum=0,idx=0;

    auto result = py::array_t<uint8_t>(frameNum*bytesInFrame);
    py::buffer_info sort_buf_info = result.request();
    uint8_t *sort_buf_ptr = static_cast<uint8_t *>(sort_buf_info.ptr);

    py::buffer_info buf_info = buf.request();
    uint8_t *buf_ptr = static_cast<uint8_t *>(buf_info.ptr);

    //first packet
    firstPacketNum = *(uint32_t *)buf_ptr;//4 bytes of sequence number for every packet
    cpySize = payloadSize-lastFrameRemainBytes;
    memcpy(sort_buf_ptr, &buf_ptr[lastFrameRemainBytes], cpySize);
    receivedPacketNum = 1;

    //rest packet
    for(uint32_t i=1;i<packetNum;i++){
        seqNum=*(uint32_t *)&buf_ptr[i*packetSize];//4 bytes of sequence number for every packet
        //byteCnt=*(uint32_t *)&buf_ptr[i*packetSize+4];//6 bytes of byte count – provides information about number of bytes transmitted till last packet.
        idx = seqNum-firstPacketNum;
        if(idx<1 || idx>packetNum-1) continue;//out of boundary
        if(idx==packetNum-1){//last packet
            memcpy(&sort_buf_ptr[(idx-1)*payloadSize+cpySize], &buf_ptr[i*packetSize+10], frameNum*bytesInFrame-idx*payloadSize+lastFrameRemainBytes);
        }else{//middle packet
            memcpy(&sort_buf_ptr[(idx-1)*payloadSize+cpySize], &buf_ptr[i*packetSize+10], payloadSize);//1456 bytes of payload
        }
        receivedPacketNum++;
    }

    lastPacketNum = *(uint32_t *)&buf_ptr[(packetNum-1)*packetSize];
    // printf("[fpga_udp]received packet num:%d,expected packet num:%d\n",receivedPacketNum,packetNum);

    return result;
}

// void _read_data_udp_buffered(int sock_fd, uint32_t bufFrameNum, int bytesInFrame, int packetSize, int timeout_s){
//     uint32_t maxPacketNum = ((bufFrameNum+1)*bytesInFrame)/(packetSize-10)+1;
//     firstBufFull=false;
//     auto packetBuf = py::array_t<uint8_t>(maxPacketNum*packetSize);
//     doubleBuffer[0] = py::array_t<uint8_t>(bufFrameNum*bytesInFrame);
//     doubleBuffer[1] = py::array_t<uint8_t>(bufFrameNum*bytesInFrame);
// }

py::array_t<uint8_t> read_data_udp(int sock_fd, uint32_t frameNum, int bytesInFrame, int packetSize, int timeout_s, bool sort){
    uint32_t maxPacketNum = ((frameNum+1)*bytesInFrame)/(packetSize-10)+1;
    /* No pointer is passed, so NumPy will allocate the buffer */
    auto result = py::array_t<uint8_t>(maxPacketNum*packetSize);
    int lastFrameRemainBytes=0;

    _read_data_udp(sock_fd,frameNum,bytesInFrame,packetSize,lastFrameRemainBytes,timeout_s,result);

    if(sort) return postProc_packet_sort(result,frameNum,bytesInFrame,packetSize,lastFrameRemainBytes,receivedPacketNum_g,firstPacketNum_g,lastPacketNum_g);

    return result;
}

py::array_t<uint8_t> read_data_udp_block_thread(int sock_fd, uint32_t frameNum, int bytesInFrame, int packetSize, int timeout_s, bool sort){
    uint32_t maxPacketNum = ((frameNum+1)*bytesInFrame)/(packetSize-10)+1;
    /* No pointer is passed, so NumPy will allocate the buffer */
    auto result = py::array_t<uint8_t>(maxPacketNum*packetSize);
    int lastFrameRemainBytes=0;

    std::thread udp_thread(_read_data_udp,sock_fd,frameNum,bytesInFrame,packetSize,std::ref(lastFrameRemainBytes),timeout_s,result);
    udp_thread.join();

    if(sort) return postProc_packet_sort(result,frameNum,bytesInFrame,packetSize,lastFrameRemainBytes,receivedPacketNum_g,firstPacketNum_g,lastPacketNum_g);

    return result;
}

void read_data_udp_async_start(int sock_fd, uint32_t frameNum, int bytesInFrame, int packetSize, int timeout_s, bool sort){
    udp_async_mutex.lock();
    udp_val = std::async(std::launch::async, read_data_udp, sock_fd,frameNum,bytesInFrame,packetSize,timeout_s,sort);
}

py::array_t<uint8_t> read_data_udp_async_wait(){
    udp_async_mutex.unlock();
    return udp_val.get();
}

UdpFileStats read_data_udp_to_file_worker(int sock_fd, uint32_t frameNum, int bytesInFrame, int packetSize, int timeout_s, bool sort, std::string outputPath){
    udp_mutex.lock();
    UdpFileStats stats;
    stats.outputPath = outputPath;
    stats.expectedRawBytes = static_cast<uint64_t>(frameNum)*static_cast<uint64_t>(bytesInFrame);
    stats.sorted = sort;

    if(packetSize%2 != 0){
        udp_mutex.unlock();
        throw std::runtime_error("[fpga_udp]Number of packetSize must be even");
    }

    #ifdef __linux__
        int sockfd = sock_fd;
        struct timeval tv;
        tv.tv_sec  = timeout_s;
        tv.tv_usec = 0;
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(struct timeval));
    #elif _WIN32
        SOCKET sockfd = (SOCKET)sock_fd;
        int TimeOut = timeout_s*1000;
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&TimeOut, sizeof(TimeOut));
    #endif

    uint32_t maxPacketNum = ((frameNum+1)*bytesInFrame)/(packetSize-10)+1;
    std::vector<uint8_t> packetBuf(static_cast<size_t>(maxPacketNum)*static_cast<size_t>(packetSize));
    int lastFrameRemainBytes=0;
    struct sockaddr_in src;
    socklen_t src_len = sizeof(src);
    memset(&src, 0, sizeof(src));

    uint32_t seqNum=0;
    uint64_t bytesCnt;
    int receivePacketLen=0,lastFrameTransferedBytes;

    do{
        receivePacketLen=recvfrom(sockfd, (char*)packetBuf.data(), packetSize, 0, (sockaddr*)&src, &src_len);
        if (receivePacketLen < 0){
            udp_mutex.unlock();
            throw std::runtime_error("[fpga_udp]udp time out before frame start");
        }
        seqNum = *(uint32_t *)packetBuf.data();
        bytesCnt = (seqNum-1)*(packetSize-10);
        lastFrameTransferedBytes = bytesCnt % bytesInFrame;
        lastFrameRemainBytes = (bytesInFrame-lastFrameTransferedBytes) % bytesInFrame;
    }while(lastFrameRemainBytes>=packetSize-10);

    uint32_t expectedPacketNum = ceil((lastFrameRemainBytes + frameNum*bytesInFrame)/((double)(packetSize-10)));
    stats.expectedPacketNum = expectedPacketNum;

    for(uint32_t i=1;i<expectedPacketNum;i++){
        int idx = i*packetSize;
        receivePacketLen=recvfrom(sockfd, (char*)&packetBuf[idx], packetSize, 0, (sockaddr*)&src, &src_len);
        if (receivePacketLen < 0){
            printf("[fpga_udp]udp time out\n");
            break;
        }
    }
    udp_mutex.unlock();

    const int payloadSize = packetSize-10;
    std::vector<uint8_t> sortedBuf;
    uint8_t *outPtr = packetBuf.data();
    uint64_t outBytes = static_cast<uint64_t>(expectedPacketNum)*static_cast<uint64_t>(packetSize);
    if(sort){
        sortedBuf.assign(static_cast<size_t>(frameNum)*static_cast<size_t>(bytesInFrame), 0);
        uint8_t *sort_buf_ptr = sortedBuf.data();
        uint8_t *buf_ptr = packetBuf.data();
        uint32_t firstPacketNum = *(uint32_t *)buf_ptr;
        int cpySize = payloadSize-lastFrameRemainBytes;
        memcpy(sort_buf_ptr, &buf_ptr[lastFrameRemainBytes], cpySize);
        uint32_t receivedPacketNum = 1;
        uint32_t lastPacketNum = firstPacketNum;

        for(uint32_t i=1;i<expectedPacketNum;i++){
            seqNum=*(uint32_t *)&buf_ptr[i*packetSize];
            uint32_t idx = seqNum-firstPacketNum;
            if(idx<1 || idx>expectedPacketNum-1) continue;
            if(idx==expectedPacketNum-1){
                memcpy(&sort_buf_ptr[(idx-1)*payloadSize+cpySize], &buf_ptr[i*packetSize+10], frameNum*bytesInFrame-idx*payloadSize+lastFrameRemainBytes);
            }else{
                memcpy(&sort_buf_ptr[(idx-1)*payloadSize+cpySize], &buf_ptr[i*packetSize+10], payloadSize);
            }
            receivedPacketNum++;
        }
        lastPacketNum = *(uint32_t *)&buf_ptr[(expectedPacketNum-1)*packetSize];
        stats.receivedPacketNum = receivedPacketNum;
        stats.firstPacketNum = firstPacketNum;
        stats.lastPacketNum = lastPacketNum;
        outPtr = sortedBuf.data();
        outBytes = stats.expectedRawBytes;
    }

    std::string tmpPath = outputPath + ".part";
    std::ofstream outFile(tmpPath, std::ios::binary | std::ios::out | std::ios::trunc);
    if(!outFile){
        throw std::runtime_error("[fpga_udp]failed to open output file: " + tmpPath);
    }
    outFile.write(reinterpret_cast<const char *>(outPtr), outBytes);
    outFile.close();
    if(!outFile){
        throw std::runtime_error("[fpga_udp]failed while writing output file: " + tmpPath);
    }
    if(std::rename(tmpPath.c_str(), outputPath.c_str()) != 0){
        throw std::runtime_error("[fpga_udp]failed to rename output file: " + tmpPath + " -> " + outputPath);
    }
    stats.rawBytesWritten = outBytes;
    expectedPacketNum_g = stats.expectedPacketNum;
    receivedPacketNum_g = stats.receivedPacketNum;
    firstPacketNum_g = stats.firstPacketNum;
    lastPacketNum_g = stats.lastPacketNum;
    return stats;
}

py::dict udp_file_stats_to_dict(const UdpFileStats &stats){
    py::dict result;
    result["output_path"] = stats.outputPath;
    result["raw_bytes_written"] = py::int_(stats.rawBytesWritten);
    result["expected_raw_bytes"] = py::int_(stats.expectedRawBytes);
    result["copied_raw_bytes"] = py::int_(stats.copiedRawBytes);
    result["expected_packet_num"] = stats.expectedPacketNum;
    result["received_packet_num"] = stats.receivedPacketNum;
    result["first_packet_num"] = stats.firstPacketNum;
    result["last_packet_num"] = stats.lastPacketNum;
    result["queue_capacity_packets"] = stats.queueCapacityPackets;
    result["queue_peak_packets"] = stats.queuePeakPackets;
    result["short_packet_num"] = stats.shortPacketNum;
    result["timed_out"] = stats.timedOut;
    result["sorted"] = stats.sorted;
    return result;
}

py::dict read_data_udp_to_file(int sock_fd, uint32_t frameNum, int bytesInFrame, int packetSize, int timeout_s, bool sort, std::string outputPath){
    return udp_file_stats_to_dict(read_data_udp_to_file_worker(sock_fd, frameNum, bytesInFrame, packetSize, timeout_s, sort, outputPath));
}

void read_data_udp_to_file_async_start(int sock_fd, uint32_t frameNum, int bytesInFrame, int packetSize, int timeout_s, bool sort, std::string outputPath){
    udp_async_mutex.lock();
    udp_file_val = std::async(std::launch::async, read_data_udp_to_file_worker, sock_fd,frameNum,bytesInFrame,packetSize,timeout_s,sort,outputPath);
}

py::dict read_data_udp_to_file_async_wait(){
    udp_async_mutex.unlock();
    return udp_file_stats_to_dict(udp_file_val.get());
}

UdpFileStats read_data_udp_frames_to_file_worker(
    int sock_fd,
    uint32_t frameNum,
    int bytesInFrame,
    int packetSize,
    int timeout_s,
    std::string outputPath,
    uint32_t chunkFrameNum,
    uint32_t reorderMarginFrameNum
){
    udp_mutex.lock();
    UdpFileStats stats;
    stats.outputPath = outputPath;
    stats.expectedRawBytes = static_cast<uint64_t>(frameNum)*static_cast<uint64_t>(bytesInFrame);
    stats.sorted = true;

    if(packetSize != packetSize_d){
        udp_mutex.unlock();
        throw std::runtime_error("[fpga_udp]framefile reader currently requires packetSize=1466");
    }
    if(bytesInFrame <= 0 || frameNum == 0){
        udp_mutex.unlock();
        throw std::runtime_error("[fpga_udp]invalid frame geometry");
    }

    const int payloadSize = packetSize - 10;
    uint64_t totalBytes = stats.expectedRawBytes;
    uint64_t chunkBytes = static_cast<uint64_t>(std::max<uint32_t>(1, chunkFrameNum))*static_cast<uint64_t>(bytesInFrame);
    uint64_t reorderMarginBytes = static_cast<uint64_t>(reorderMarginFrameNum)*static_cast<uint64_t>(bytesInFrame);
    std::vector<uint8_t> chunkBuf(static_cast<size_t>(chunkBytes), 0);
    std::vector<uint8_t> packetBuf(static_cast<size_t>(packetSize), 0);

    #ifdef __linux__
        int sockfd = sock_fd;
        struct timeval tv;
        tv.tv_sec  = timeout_s;
        tv.tv_usec = 0;
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(struct timeval));
    #elif _WIN32
        SOCKET sockfd = (SOCKET)sock_fd;
        int TimeOut = timeout_s*1000;
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&TimeOut, sizeof(TimeOut));
    #endif

    struct sockaddr_in src;
    socklen_t src_len = sizeof(src);
    memset(&src, 0, sizeof(src));

    uint32_t seqNum=0;
    uint32_t firstSeqNum=0;
    uint64_t packetDataStart=0;
    int receivePacketLen=0,lastFrameTransferedBytes=0,lastFrameRemainBytes=0;

    do{
        receivePacketLen=recvfrom(sockfd, (char*)packetBuf.data(), packetSize, 0, (sockaddr*)&src, &src_len);
        if (receivePacketLen < 0){
            udp_mutex.unlock();
            throw std::runtime_error("[fpga_udp]udp time out before frame start");
        }
        seqNum = *(uint32_t *)packetBuf.data();
        packetDataStart = static_cast<uint64_t>(seqNum-1)*static_cast<uint64_t>(payloadSize);
        lastFrameTransferedBytes = packetDataStart % bytesInFrame;
        lastFrameRemainBytes = (bytesInFrame-lastFrameTransferedBytes) % bytesInFrame;
    }while(lastFrameRemainBytes>=payloadSize);

    uint64_t captureStartByte = packetDataStart + static_cast<uint64_t>(lastFrameRemainBytes);
    uint64_t captureEndByte = captureStartByte + totalBytes;
    firstSeqNum = seqNum;
    uint64_t chunkBaseOffset = 0;
    uint64_t copiedBytes = 0;
    uint32_t receivedPackets = 0;
    bool done = false;

    std::string tmpPath = outputPath + ".part";
    std::ofstream outFile(tmpPath, std::ios::binary | std::ios::out | std::ios::trunc);
    if(!outFile){
        udp_mutex.unlock();
        throw std::runtime_error("[fpga_udp]failed to open output file: " + tmpPath);
    }

    auto flush_one_chunk = [&]() {
        uint64_t remaining = totalBytes - chunkBaseOffset;
        uint64_t bytesToWrite = std::min<uint64_t>(chunkBytes, remaining);
        if(bytesToWrite > 0){
            outFile.write(reinterpret_cast<const char *>(chunkBuf.data()), bytesToWrite);
        }
        std::fill(chunkBuf.begin(), chunkBuf.end(), 0);
        chunkBaseOffset += bytesToWrite;
    };

    auto flush_until = [&](uint64_t safeOffset) {
        while(chunkBaseOffset + chunkBytes <= safeOffset && chunkBaseOffset < totalBytes){
            flush_one_chunk();
        }
    };

    auto copy_packet_payload = [&](const std::vector<uint8_t> &packet) {
        uint32_t packetSeq = *(uint32_t *)packet.data();
        if(packetSeq == 0){
            return;
        }
        uint64_t dataStart = static_cast<uint64_t>(packetSeq-1)*static_cast<uint64_t>(payloadSize);
        uint64_t dataEnd = dataStart + payloadSize;
        if(dataEnd <= captureStartByte || dataStart >= captureEndByte){
            return;
        }
        uint64_t overlapStart = std::max<uint64_t>(dataStart, captureStartByte);
        uint64_t overlapEnd = std::min<uint64_t>(dataEnd, captureEndByte);
        uint64_t packetOffset = overlapStart - dataStart;
        uint64_t captureOffset = overlapStart - captureStartByte;
        uint64_t len = overlapEnd - overlapStart;
        const uint8_t *payload = packet.data() + 10;

        while(len > 0){
            if(captureOffset < chunkBaseOffset){
                uint64_t skip = std::min<uint64_t>(len, chunkBaseOffset - captureOffset);
                captureOffset += skip;
                packetOffset += skip;
                len -= skip;
                continue;
            }
            while(captureOffset >= chunkBaseOffset + chunkBytes && chunkBaseOffset < totalBytes){
                flush_one_chunk();
            }
            uint64_t localOffset = captureOffset - chunkBaseOffset;
            uint64_t canCopy = std::min<uint64_t>(len, chunkBytes - localOffset);
            if(canCopy == 0){
                break;
            }
            memcpy(chunkBuf.data() + localOffset, payload + packetOffset, canCopy);
            copiedBytes += canCopy;
            captureOffset += canCopy;
            packetOffset += canCopy;
            len -= canCopy;
        }
    };

    while(!done){
        copy_packet_payload(packetBuf);
        receivedPackets++;
        uint64_t packetEnd = packetDataStart + payloadSize;
        if(packetEnd >= captureEndByte){
            done = true;
            break;
        }
        uint64_t seenOffset = 0;
        if(packetEnd > captureStartByte){
            seenOffset = std::min<uint64_t>(packetEnd - captureStartByte, totalBytes);
        }
        if(seenOffset > reorderMarginBytes){
            flush_until(seenOffset - reorderMarginBytes);
        }

        receivePacketLen=recvfrom(sockfd, (char*)packetBuf.data(), packetSize, 0, (sockaddr*)&src, &src_len);
        if (receivePacketLen < 0){
            printf("[fpga_udp]udp time out\n");
            break;
        }
        seqNum = *(uint32_t *)packetBuf.data();
        packetDataStart = static_cast<uint64_t>(seqNum-1)*static_cast<uint64_t>(payloadSize);
    }

    while(chunkBaseOffset < totalBytes){
        flush_one_chunk();
    }
    outFile.close();
    udp_mutex.unlock();

    if(!outFile){
        throw std::runtime_error("[fpga_udp]failed while writing output file: " + tmpPath);
    }
    if(std::rename(tmpPath.c_str(), outputPath.c_str()) != 0){
        throw std::runtime_error("[fpga_udp]failed to rename output file: " + tmpPath + " -> " + outputPath);
    }

    stats.rawBytesWritten = totalBytes;
    stats.expectedPacketNum = static_cast<uint32_t>(ceil((lastFrameRemainBytes + frameNum*bytesInFrame)/((double)payloadSize)));
    stats.receivedPacketNum = receivedPackets;
    stats.firstPacketNum = firstSeqNum;
    stats.lastPacketNum = seqNum;
    expectedPacketNum_g = stats.expectedPacketNum;
    receivedPacketNum_g = stats.receivedPacketNum;
    firstPacketNum_g = stats.firstPacketNum;
    lastPacketNum_g = stats.lastPacketNum;
    return stats;
}

void read_data_udp_frames_to_file_async_start(
    int sock_fd,
    uint32_t frameNum,
    int bytesInFrame,
    int packetSize,
    int timeout_s,
    std::string outputPath,
    uint32_t chunkFrameNum,
    uint32_t reorderMarginFrameNum
){
    udp_async_mutex.lock();
    udp_file_val = std::async(
        std::launch::async,
        read_data_udp_frames_to_file_worker,
        sock_fd,
        frameNum,
        bytesInFrame,
        packetSize,
        timeout_s,
        outputPath,
        chunkFrameNum,
        reorderMarginFrameNum
    );
}

UdpFileStats read_data_udp_frames_to_file2_worker(
    int sock_fd,
    uint32_t frameNum,
    int bytesInFrame,
    int packetSize,
    int timeout_s,
    std::string outputPath,
    uint32_t chunkFrameNum,
    uint32_t reorderMarginFrameNum,
    uint32_t queuePacketCapacity,
    int socketReceiveBufferBytes
){
    udp_mutex.lock();
    UdpFileStats stats;
    stats.outputPath = outputPath;
    stats.expectedRawBytes = static_cast<uint64_t>(frameNum)*static_cast<uint64_t>(bytesInFrame);
    stats.sorted = true;

    if(packetSize != packetSize_d){
        udp_mutex.unlock();
        throw std::runtime_error("[fpga_udp]framefile2 reader currently requires packetSize=1466");
    }
    if(bytesInFrame <= 0 || frameNum == 0){
        udp_mutex.unlock();
        throw std::runtime_error("[fpga_udp]invalid frame geometry");
    }

    #ifdef __linux__
        int sockfd = sock_fd;
        if(socketReceiveBufferBytes > 0){
            setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, (const char*)&socketReceiveBufferBytes, sizeof(socketReceiveBufferBytes));
        }
        int flags = fcntl(sockfd, F_GETFL, 0);
        if(flags != -1){
            fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);
        }
    #elif _WIN32
        SOCKET sockfd = (SOCKET)sock_fd;
        if(socketReceiveBufferBytes > 0){
            setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, (const char*)&socketReceiveBufferBytes, sizeof(socketReceiveBufferBytes));
        }
        unsigned long mode = 1;
        ioctlsocket(sockfd, FIONBIO, &mode);
    #endif

    const int payloadSize = packetSize - 10;
    const uint64_t totalBytes = stats.expectedRawBytes;
    const uint64_t chunkBytes = static_cast<uint64_t>(std::max<uint32_t>(1, chunkFrameNum))*static_cast<uint64_t>(bytesInFrame);
    const uint64_t reorderMarginBytes = static_cast<uint64_t>(reorderMarginFrameNum)*static_cast<uint64_t>(bytesInFrame);
    const uint32_t queueCapacity = std::max<uint32_t>(queuePacketCapacity, 4096);
    stats.queueCapacityPackets = roundup_pow_of_two(queueCapacity);

    UnlockQueue<packet_t> packetQueue(queueCapacity);
    std::atomic<bool> rxContinue(true);
    std::atomic<uint32_t> rxReceived(0);
    std::atomic<uint32_t> rxShort(0);
    std::atomic<uint32_t> rxFirstSeq(0);
    std::atomic<uint32_t> rxLastSeq(0);
    std::atomic<uint32_t> rxQueuePeak(0);
    std::atomic<uint32_t> writerObservedSeq(0);

    std::thread rxThread([&]() {
        struct sockaddr_in src;
        socklen_t src_len = sizeof(src);
        memset(&src, 0, sizeof(src));
        packet_t packet;
        while(rxContinue.load(std::memory_order_acquire)){
            int n = recvfrom(sockfd, (char *)&packet, packetSize_d, 0, (sockaddr*)&src, &src_len);
            if(n > 0){
                if(n < packetSize_d){
                    rxShort.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }
                uint32_t seq = packet.seqNum;
                uint32_t expectedZero = 0;
                rxFirstSeq.compare_exchange_strong(expectedZero, seq, std::memory_order_acq_rel);
                rxLastSeq.store(seq, std::memory_order_release);
                rxReceived.fetch_add(1, std::memory_order_relaxed);
                packetQueue.Put(&packet, 1);
                uint32_t len = packetQueue.length();
                uint32_t oldPeak = rxQueuePeak.load(std::memory_order_relaxed);
                while(len > oldPeak && !rxQueuePeak.compare_exchange_weak(oldPeak, len, std::memory_order_relaxed)){
                }
            }else{
                std::this_thread::sleep_for(std::chrono::microseconds(50));
            }
        }
    });

    std::vector<uint8_t> chunkBuf(static_cast<size_t>(chunkBytes), 0);
    packet_t packet;
    int lastFrameRemainBytes = 0;
    uint64_t captureStartByte = 0;
    uint64_t captureEndByte = 0;
    uint64_t chunkBaseOffset = 0;
    uint64_t copiedBytes = 0;
    bool gotStart = false;
    bool done = false;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_s + 30);
    auto lastPacketObservedAt = std::chrono::steady_clock::now();
    const auto idleAfterStartTimeout = std::chrono::milliseconds(750);

    std::string tmpPath = outputPath + ".part";
    std::ofstream outFile(tmpPath, std::ios::binary | std::ios::out | std::ios::trunc);
    if(!outFile){
        rxContinue.store(false, std::memory_order_release);
        rxThread.join();
        udp_mutex.unlock();
        throw std::runtime_error("[fpga_udp]failed to open output file: " + tmpPath);
    }

    auto flush_one_chunk = [&]() {
        uint64_t remaining = totalBytes - chunkBaseOffset;
        uint64_t bytesToWrite = std::min<uint64_t>(chunkBytes, remaining);
        if(bytesToWrite > 0){
            outFile.write(reinterpret_cast<const char *>(chunkBuf.data()), bytesToWrite);
        }
        std::fill(chunkBuf.begin(), chunkBuf.end(), 0);
        chunkBaseOffset += bytesToWrite;
    };
    auto flush_until = [&](uint64_t safeOffset) {
        while(chunkBaseOffset + chunkBytes <= safeOffset && chunkBaseOffset < totalBytes){
            flush_one_chunk();
        }
    };
    auto copy_packet_payload = [&](const packet_t &pkt) {
        uint32_t packetSeq = pkt.seqNum;
        if(packetSeq == 0 || !gotStart){
            return;
        }
        uint64_t dataStart = static_cast<uint64_t>(packetSeq-1)*static_cast<uint64_t>(payloadSize);
        uint64_t dataEnd = dataStart + payloadSize;
        if(dataEnd <= captureStartByte || dataStart >= captureEndByte){
            return;
        }
        uint64_t overlapStart = std::max<uint64_t>(dataStart, captureStartByte);
        uint64_t overlapEnd = std::min<uint64_t>(dataEnd, captureEndByte);
        uint64_t packetOffset = overlapStart - dataStart;
        uint64_t captureOffset = overlapStart - captureStartByte;
        uint64_t len = overlapEnd - overlapStart;
        const uint8_t *payload = pkt.payload;

        while(len > 0){
            if(captureOffset < chunkBaseOffset){
                uint64_t skip = std::min<uint64_t>(len, chunkBaseOffset - captureOffset);
                captureOffset += skip;
                packetOffset += skip;
                len -= skip;
                continue;
            }
            while(captureOffset >= chunkBaseOffset + chunkBytes && chunkBaseOffset < totalBytes){
                flush_one_chunk();
            }
            uint64_t localOffset = captureOffset - chunkBaseOffset;
            uint64_t canCopy = std::min<uint64_t>(len, chunkBytes - localOffset);
            if(canCopy == 0){
                break;
            }
            memcpy(chunkBuf.data() + localOffset, payload + packetOffset, canCopy);
            copiedBytes += canCopy;
            captureOffset += canCopy;
            packetOffset += canCopy;
            len -= canCopy;
        }
    };

    while(!done){
        uint32_t got = packetQueue.Get(&packet, 1);
        if(got < 1){
            if(gotStart && std::chrono::steady_clock::now() - lastPacketObservedAt > idleAfterStartTimeout){
                stats.timedOut = true;
                break;
            }
            if(std::chrono::steady_clock::now() > deadline){
                stats.timedOut = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::microseconds(100));
            continue;
        }
        lastPacketObservedAt = std::chrono::steady_clock::now();
        uint32_t seq = packet.seqNum;
        writerObservedSeq.store(seq, std::memory_order_release);
        uint64_t packetDataStart = static_cast<uint64_t>(seq-1)*static_cast<uint64_t>(payloadSize);

        if(!gotStart){
            int lastFrameTransferedBytes = packetDataStart % bytesInFrame;
            lastFrameRemainBytes = (bytesInFrame-lastFrameTransferedBytes) % bytesInFrame;
            if(lastFrameRemainBytes >= payloadSize){
                continue;
            }
            captureStartByte = packetDataStart + static_cast<uint64_t>(lastFrameRemainBytes);
            captureEndByte = captureStartByte + totalBytes;
            stats.firstPacketNum = seq;
            gotStart = true;
        }

        copy_packet_payload(packet);
        uint64_t packetEnd = packetDataStart + payloadSize;
        if(packetEnd >= captureEndByte){
            done = true;
            break;
        }
        uint64_t seenOffset = 0;
        if(packetEnd > captureStartByte){
            seenOffset = std::min<uint64_t>(packetEnd - captureStartByte, totalBytes);
        }
        if(seenOffset > reorderMarginBytes){
            flush_until(seenOffset - reorderMarginBytes);
        }
    }

    rxContinue.store(false, std::memory_order_release);
    if(rxThread.joinable()){
        rxThread.join();
    }

    while(chunkBaseOffset < totalBytes){
        flush_one_chunk();
    }
    outFile.close();
    udp_mutex.unlock();

    if(!outFile){
        throw std::runtime_error("[fpga_udp]failed while writing output file: " + tmpPath);
    }
    if(std::rename(tmpPath.c_str(), outputPath.c_str()) != 0){
        throw std::runtime_error("[fpga_udp]failed to rename output file: " + tmpPath + " -> " + outputPath);
    }

    stats.rawBytesWritten = totalBytes;
    stats.copiedRawBytes = copiedBytes;
    stats.expectedPacketNum = static_cast<uint32_t>(ceil((lastFrameRemainBytes + frameNum*bytesInFrame)/((double)payloadSize)));
    stats.receivedPacketNum = rxReceived.load(std::memory_order_acquire);
    if(stats.firstPacketNum == 0){
        stats.firstPacketNum = rxFirstSeq.load(std::memory_order_acquire);
    }
    stats.lastPacketNum = rxLastSeq.load(std::memory_order_acquire);
    stats.queuePeakPackets = rxQueuePeak.load(std::memory_order_acquire);
    stats.shortPacketNum = rxShort.load(std::memory_order_acquire);
    expectedPacketNum_g = stats.expectedPacketNum;
    receivedPacketNum_g = stats.receivedPacketNum;
    firstPacketNum_g = stats.firstPacketNum;
    lastPacketNum_g = stats.lastPacketNum;
    return stats;
}

void read_data_udp_frames_to_file2_async_start(
    int sock_fd,
    uint32_t frameNum,
    int bytesInFrame,
    int packetSize,
    int timeout_s,
    std::string outputPath,
    uint32_t chunkFrameNum,
    uint32_t reorderMarginFrameNum,
    uint32_t queuePacketCapacity,
    int socketReceiveBufferBytes
){
    udp_async_mutex.lock();
    udp_file_val = std::async(
        std::launch::async,
        read_data_udp_frames_to_file2_worker,
        sock_fd,
        frameNum,
        bytesInFrame,
        packetSize,
        timeout_s,
        outputPath,
        chunkFrameNum,
        reorderMarginFrameNum,
        queuePacketCapacity,
        socketReceiveBufferBytes
    );
}

void _udp_read_thread(int sock_fd){
    udp_mutex.lock();

    #ifdef __linux__
        int sockfd = sock_fd;
        int status = fcntl(sockfd, F_SETFL, fcntl(sockfd, F_GETFL, 0) | O_NONBLOCK); // non-blocking
        if(status == -1)
            throw std::runtime_error("[fpga_udp]error calling fcntl to set O_NONBLOCK");
    #elif _WIN32
        SOCKET sockfd = (SOCKET)sock_fd;
        unsigned long mode = 1; // 1 to enable non-blocking socket
        int status = ioctlsocket(sockfd, FIONBIO, &mode);
        if(status != 0)
            throw std::runtime_error("[fpga_udp]ioctlsocket failed:"+std::to_string(WSAGetLastError()));
    #endif

    struct sockaddr_in src;
    socklen_t src_len = sizeof(src);
    memset(&src, 0, sizeof(src));

    int n;
    packet_t buffer;

    while (udp_continue_g) {
        // Try to receive data in non-blocking mode
        n = recvfrom(sockfd, (char *)&buffer, packetSize_d,
                     0, (sockaddr*)&src, &src_len);
        if (n > 0) { // Data received
            // if(n!=packetSize_d){
            //     printf("[fpga_udp]received packet length error: %d",n);
            // }
            udp_queue_g->Put(&buffer, 1);
        }else{ // No data available
            // std::this_thread::sleep_for(std::chrono::microseconds(10));
        }
    }

    udp_mutex.unlock();
}

py::array_t<uint8_t> udp_read_thread_get_frames(uint32_t frameNum, int bytesInFrame, int timeout_s, bool sort){
    uint32_t maxPacketNum = ((frameNum+1)*bytesInFrame)/(packetSize_d-10)+1;
    /* No pointer is passed, so NumPy will allocate the buffer */
    auto result = py::array_t<uint8_t>(maxPacketNum*packetSize_d);
    py::buffer_info buf_info = result.request();
    packet_t *buf_ptr = static_cast<packet_t *>(buf_info.ptr);

    int lastFrameRemainBytes=0;
    uint32_t ret;
    uint64_t bytesCnt;
    int receivePacketLen=0,lastFrameTransferedBytes;

    // Wait for start of next frame
    do{
        ret = udp_queue_g->Get_wait(buf_ptr, 1, timeout_s*1000);
        if (ret < 1){
            printf("[fpga_udp]udp time out\n");
            lastFrameRemainBytes=-1;
            return result;
        }
        bytesCnt = (buf_ptr->seqNum-1)*(packetSize_d-10);
        lastFrameTransferedBytes = bytesCnt % bytesInFrame;
        lastFrameRemainBytes = (bytesInFrame-lastFrameTransferedBytes) % bytesInFrame;
    }while(lastFrameRemainBytes>=packetSize_d-10);
    
    expectedPacketNum_g = ceil((lastFrameRemainBytes + frameNum*bytesInFrame)/((double)(packetSize_d-10)));

    // Read in the rest of the frame
    ret = udp_queue_g->Get_wait(buf_ptr+1, expectedPacketNum_g-1, timeout_s*1000);
    if (ret < expectedPacketNum_g-1)
        printf("[fpga_udp]udp time out\n");

    if(sort) return postProc_packet_sort(result,frameNum,bytesInFrame,packetSize_d,lastFrameRemainBytes,receivedPacketNum_g,firstPacketNum_g,lastPacketNum_g);
    return result;
}

PYBIND11_MODULE(fpga_udp, m) {
    m.doc() = R"pbdoc(
        FPGA UDP reader & mmwavelink API plugin
        -----------------------

        .. currentmodule:: fpga_udp

        .. autosummary::
           :toctree: _generate

           add
           subtract

           radar_start_read_thread
           get_radar_buf
           radar_stop_read_thread
           getOverflowCnt

           read_data_udp
           read_data_udp_block_thread
           read_data_udp_async_start
           read_data_udp_async_wait
           read_data_udp_to_file_async_start
           read_data_udp_to_file_async_wait
           read_data_udp_frames_to_file_async_start
           read_data_udp_frames_to_file2_async_start
           get_receivedPacketNum
           get_firstPacketNum
           get_lastPacketNum
           get_expectedPacketNum
           udp_read_thread_init
           udp_read_thread_start
           udp_read_thread_get_frames
           udp_read_thread_stop

           AWR2243_firmwareDownload
           AWR2243_init
           AWR2243_setFrameCfg
           AWR2243_sensorStart
           AWR2243_isSensorStarted
           AWR2243_waitSensorStop
           AWR2243_sensorStop
           AWR2243_sensorStartCont
           AWR2243_sensorStopCont
           AWR2243_poweroff
           AWR2243_test_demo_app
    )pbdoc";

    m.def("radar_start_read_thread", &radar_start_read_thread);
    m.def("get_radar_buf", &get_radar_buf);
    m.def("radar_stop_read_thread", &radar_stop_read_thread);
    m.def("getOverflowCnt", []() {
        return overflowCnt;
    });
    m.def("reset_radar_buf", []() {
        serial_buf_mutex.lock();
        memidx=0;
        overflowCnt=0;
        serial_buf_mutex.unlock();
    });

    m.def("read_data_udp", &read_data_udp, R"pbdoc(
        read UDP packet from FPGA as fast as written in C.

        sockfd:\tan open file descriptor of a socket
        frameNum:\tA total of frameNum frames will be read
        bytesInFrame:\tbytes of one frame
        packetSize:\tand the size of each packet is packetSize
        timeout_s:\ttime out for udp in sec
    )pbdoc");
    m.def("read_data_udp_block_thread", &read_data_udp_block_thread, R"pbdoc(
        read UDP packet from FPGA using thread, block untill data transfer finished.

        sockfd:\tan open file descriptor of a socket
        frameNum:\tA total of frameNum frames will be read
        bytesInFrame:\tbytes of one frame
        packetSize:\tand the size of each packet is packetSize
        timeout_s:\ttime out for udp in sec
    )pbdoc");
    m.def("read_data_udp_async_start", &read_data_udp_async_start, R"pbdoc(
        read UDP packet from FPGA using async, return immediately.

        sockfd:\tan open file descriptor of a socket
        frameNum:\tA total of frameNum frames will be read
        bytesInFrame:\tbytes of one frame
        packetSize:\tand the size of each packet is packetSize
        timeout_s:\ttime out for udp in sec
    )pbdoc");
    m.def("read_data_udp_async_wait", &read_data_udp_async_wait, R"pbdoc(
        read UDP packet from FPGA using async, wait previous async task finished.
    )pbdoc");
    m.def("read_data_udp_to_file", &read_data_udp_to_file, R"pbdoc(
        read UDP packet from FPGA, sort it, and write the raw ADC bytes directly to a file.
    )pbdoc");
    m.def("read_data_udp_to_file_async_start", &read_data_udp_to_file_async_start, R"pbdoc(
        start asynchronous UDP capture and write sorted raw ADC bytes directly to a file.
    )pbdoc");
    m.def("read_data_udp_to_file_async_wait", &read_data_udp_to_file_async_wait, R"pbdoc(
        wait for the previous asynchronous UDP-to-file capture to finish.
    )pbdoc");
    m.def("read_data_udp_frames_to_file_async_start", &read_data_udp_frames_to_file_async_start, R"pbdoc(
        start asynchronous UDP capture and write sorted raw ADC bytes in frame chunks directly to a file.
    )pbdoc");
    m.def("read_data_udp_frames_to_file2_async_start", &read_data_udp_frames_to_file2_async_start, R"pbdoc(
        start experimental two-thread UDP capture: one receiver thread feeds a large packet queue, one writer thread sorts frame chunks to disk.
    )pbdoc");
    m.def("get_receivedPacketNum", []() {return receivedPacketNum_g;});
    m.def("get_firstPacketNum", []() {return firstPacketNum_g;});
    m.def("get_lastPacketNum", []() {return lastPacketNum_g;});
    m.def("get_expectedPacketNum", []() {return expectedPacketNum_g;});
    m.def("udp_read_thread_init", [](int bytesInFrame, int frameNumInBuf) {
        uint32_t maxPacketNum = ((frameNumInBuf+1)*bytesInFrame)/(packetSize_d-10)+1;
        udp_queue_g = new UnlockQueue<packet_t>(maxPacketNum);
        return udp_queue_g->size();
    });
    m.def("udp_read_thread_start", [](int sock_fd) {
        udp_continue_g = true;
        udp_thread_g = std::thread(_udp_read_thread, sock_fd);
    });
    m.def("udp_read_thread_get_frames", &udp_read_thread_get_frames);
    m.def("udp_read_thread_isStarted", [](){return udp_continue_g.load();});
    m.def("udp_read_thread_stop", []() {
        if(udp_continue_g){
            udp_continue_g = false;
            udp_thread_g.join();
            delete udp_queue_g;
        }
    });
    m.def("kfifo_benchmark", [](uint32_t loopTime,uint32_t maxPacketNum) {
        udp_queue_g = new UnlockQueue<packet_t>(maxPacketNum);
        packet_t buffer;
        auto start = std::chrono::system_clock::now();
        uint32_t realCnt=0;
        for(uint32_t i=0;i<loopTime;i++){
            buffer.seqNum=i;
            uint32_t ret=udp_queue_g->Put(&buffer, 1);
            if(ret!=1){
                printf("%d\n",ret);
                break;
            }
            realCnt++;
        }
        auto end   = std::chrono::system_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
        auto dur_s=double(duration.count()) * std::chrono::microseconds::period::num / std::chrono::microseconds::period::den;
        std::cout<<realCnt<<" loops cost "<<dur_s<<"sec, "<< realCnt*sizeof(packet_t)/dur_s/1024/1024 <<"MB/s"<<std::endl;

        delete udp_queue_g;
    });

    m.def("AWR2243_firmwareDownload",[](){
        return MMWL_App_firmwareDownload(RL_DEVICE_MAP_CASCADED_1);
    }, R"pbdoc(
        This function downloads meta image patch to external serial flash.
        Once the flashing operation is successful, 
        it is not necessary to download the meta image in the subsequent power cycles.
        If no flash connected or not downloaded successfully, you must set downloadFw=true
        when you call AWR2243_init and set EnableFwDownload=1 in mmwaveconfig.txt and
        MMWL_FILETYPE_META_IMG = 0 in mmw_example_nonos.h.
    )pbdoc");
    m.def("AWR2243_init",[](std::string configFilename){
        return MMWL_App_init(RL_DEVICE_MAP_CASCADED_1, configFilename.c_str(), false);
    });
    m.def("AWR2243_setSOP",[](int sopMode){
        return MMWL_SOPControl(RL_DEVICE_MAP_CASCADED_1, sopMode);
    });
    m.def("AWR2243_setFrameCfg",[](int numFrames){
        return MMWL_App_setFrameCfg(RL_DEVICE_MAP_CASCADED_1, numFrames);
    });
    m.def("AWR2243_sensorStart",[](){
        return MMWL_App_startSensor(RL_DEVICE_MAP_CASCADED_1);
    });
    m.def("AWR2243_isSensorStarted",[](){
        return MMWL_App_isSensorStarted();
    });
    m.def("AWR2243_waitSensorStop",[](){
        return MMWL_App_waitSensorStop(RL_DEVICE_MAP_CASCADED_1);
    });
    m.def("AWR2243_sensorStop",[](){
        return MMWL_App_stopSensor(RL_DEVICE_MAP_CASCADED_1);
    });
    m.def("AWR2243_sensorStartCont",[](){
        return MMWL_App_startCont(RL_DEVICE_MAP_CASCADED_1);
    }, R"pbdoc(
        This function starts the FMCW radar in continous mode.
        In continuous mode, the signal is not frequency modulated but has the same frequency over time.
        Note: The continuous streaming mode configuration APIs are supported only for debug purpose.
        Please refer latest DFP release note for more info.
    )pbdoc");
    m.def("AWR2243_sensorStopCont",[](){
        return MMWL_App_stopCont(RL_DEVICE_MAP_CASCADED_1);
    });
    m.def("AWR2243_poweroff",[](){
        return MMWL_App_poweroff(RL_DEVICE_MAP_CASCADED_1);
    });
    m.def("AWR2243_test_demo_app",[](std::string configFilename){
        return MMWL_App(configFilename.c_str());
    });
    
    m.def("add", &add, R"pbdoc(
        Add two numbers
    )pbdoc");

    m.def("subtract", [](int i, int j) {
        return i - j;
    });

#ifdef VERSION_INFO
    m.attr("__version__") = MACRO_STRINGIFY(VERSION_INFO);
#else
    m.attr("__version__") = "dev";
#endif
}
