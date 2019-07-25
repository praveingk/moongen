

local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local stats  = require "stats"
local hist   = require "histogram"
local proto	= require "proto.proto"
local timer  = require "timer"
local dpdkc  = require "dpdkc"
local dpdk   = require "dpdk"
local filter = require "filter"
local libmoon = require "libmoon"
local h = require "syscall.helpers"
local htonl = h.htonl
local ntohl = h.ntohl
local ntoh, hton = ntoh, hton

local MINION_HOST1	= "3c:fd:fe:b7:e7:f4"
local MINION_HOST2	= "3c:fd:fe:b7:e7:f5"

local TINA_HOST1	= "6C:B3:11:53:09:9C"
local TINA_HOST2	= "6C:B3:11:53:09:9E"

local HAJIME_HOST1 = "3c:fd:fe:ad:84:a4"
local HAJIME_HOST2 = "3c:fd:fe:ad:84:a5"

local BCAST = "FF:FF:FF:FF:FF:FF"
local DUMMY_DST = "3c:fd:fe:b7:e7:f9"


local HOST3	= "10:00:00:00:00:01"
local HOST4	= "20:00:00:00:00:02"


local HOST5	= "30:00:00:10:00:03"
local HOST6	= "30:00:00:20:00:03"

local HOST7	= "40:00:00:10:00:04"
local HOST8	= "40:00:00:20:00:04"


local HOST8 = "a0:00:00:10:00:0a"
local HOST9 = "a0:00:00:20:00:0a"


local TYPE_TS = 0x1235
local TOTAL_SWITCHES = 3
local UDP_PKT_SIZE = 150

function configure(parser)
	parser:description("Receives and stores the snaprr collection.")
	parser:argument("rxDev", "Device to receive from."):convert(tonumber)
	parser:option("-f --file", "Filename for collecting the replay"):default("snaprr_collect.txt")
	parser:option("-c", "Start CrossTraffic"):default(0):convert(tonumber)
end

function master(args)
  rxDev = device.config({port = args.rxDev, rxQueues = 1, txQueues = 1})
  device.waitForLinks()
	rxQueue = rxDev:getRxQueue(0)
	local count = 1
  --stats.startStatsTask{rxDev}
  mg.startTask("initiateCollect", rxQueue, count)
	if args.c == 1 then
		mg.startSharedTask("CrossTraffic", rxDev:getTxQueue(0))
	end
  mg.waitForTasks()

end

function CrossTraffic(queue)
	local mem = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			ethSrc = queue,
			ethDst = HAJIME_HOST1,
			ip4Src = SRC_IP,
			ip4Dst = DST_IP,
			udpSrc = SRC_PORT,
			udpDst = DST_PORT,
			pktLength = UDP_PKT_SIZE
		}
	end)
	local bufs = mem:bufArray(5)
	local check_id = 1
	while mg.running() do
		bufs:alloc(UDP_PKT_SIZE)
		local txBuf = bufs[1]
		txBuf:getUdpPacket().udp:setChecksum(check_id)
		txBuf:getUdpPacket().udp:setDstPort(check_id)
		--txBuf:dump()
		printf("Sending Traffic.");
		queue:send(bufs)
		mg.sleepMillis(1000)
		check_id = check_id + 1
	end
end

function dumpTopology(fp)
	fp:write("Switches\n")
	fp:write("1,00:00:00:00:00:01\n")
	fp:write("2,00:00:00:00:00:02\n")
	fp:write("9,00:00:00:00:00:09\n")
	fp:write("10,00:00:00:00:00:0a\n")
	fp:write("17,00:00:00:00:00:11\n")
	fp:write("Links\n")
	fp:write("1,9\n")
	fp:write("9,17\n")
	fp:write("10,17\n")
	fp:write("2,10\n")
	fp:write("Records\n")
end

function initiateCollect(rxQueue, count)
	local rxBufs = memory.bufArray()
	file = "snaprr_collect" .. count .. ".mf"
	fp = io.open(file, "w")
	dumpTopology(fp)
	switches_collected = 0
	local trigger_id = -1
	while mg.running() do
		local rx = rxQueue:tryRecv(rxBufs, 1000)
		for i=1,rx do
			local rxBuf = rxBufs[i]
			local rxPkt = rxBuf:getPacketrecordPacket()
			local entry_pt = 21
			local start_pt = 23
			if (rxPkt.eth:getType() == proto.eth.TYPE_TRIGGER) then
				rxBuf:dump()
				rxPkt = rxBuf:getTriggerPacket()
				if rxPkt.trigger:getId() ~= trigger_id then
					fp:write(("Trigger, %d, %d, %d\n"):format(rxPkt.trigger:getId(), rxPkt.trigger:getTriggerTime(), rxPkt.trigger:getOrigin()))
					trigger_id = rxPkt.trigger:getId()
				end
			end
			rxPkt = rxBuf:getPacketrecordPacket()
			if (rxPkt.eth:getType() == proto.eth.TYPE_PRCOLL) then
				rxBuf:dump()
				--printf("Receiving PacketRecords")
				local sz = rxBuf:getSize()
				local pkt_data = {};
				pkt_data = rxBuf:getBytes()
				if (pkt_data[entry_pt] ~= 0) then
					fp:write(("%s,"): format(rxPkt.eth:getSrcString()))
					fp:write(("%x,"):format(pkt_data[entry_pt]))
					for i=start_pt,sz do
						fp:write(("%x,"):format(pkt_data[i]))
					end
					fp:write("\n")
				end
				if rxPkt.packetrecord:isPacketRecordEnd() then
					switches_collected = switches_collected + 1
					if (switches_collected == TOTAL_SWITCHES) then
						switches_collected = 0
						count = count + 1
						printf("Done.")
						fp:close();
						return
					end
				end
			end
		end
		rxBufs:freeAll();
	end
end
