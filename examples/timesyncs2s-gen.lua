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



local ETHLOOP_SRC	= "10:00:00:00:00:01"
local ETHLOOP_DST = "20:00:00:00:00:02"


local TYPE_TS = 0x1235
local PKT_SIZE	= 60
local UDP_PKT_SIZE = 1500

function configure(parser)
	parser:description("Generates a Timesync Request, and displays the Timestamp obtained from Master Clock")
	parser:argument("txDev", "Device to transmit/receive from."):convert(tonumber)
	parser:option("-c", "Start CrossTraffic"):default(0):convert(tonumber)
	parser:option("-d", "Start receiving CrossTraffic"):default(0):convert(tonumber)

	parser:option("-f --file", "Filename of the latency histogram."):default("timesync.csv")
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
end

function master(args)
  -- txDev = device.config({port = args.txDev, rxQueues = 2, txQueues = 2})
  txDev = device.config{port = args.txDev, txQueues = 1, disableOffloads = true}
  device.waitForLinks()
	txQueue = txDev:getTxQueue(0)
--	rxQueue = txDev:getRxQueue(0)

	txQueue:enableTimestamps()
--	rxQueue:enableTimestamps()

	-- Below is a mandatory and important command to put Timesync packets to RX Queue 1.
--	rxQueue:filterL2Timestamps()
	printf("CrossTraffic=%d", args.c)

	if args.c == 1 then
		mg.startSharedTask("CrossTraffic", txDev:getTxQueue(0))
	end
	if args.d == 1 then
	 		printf("Starting to receive CrossTraffic")

			--device.waitForLinks()
--	   	txDev:getTxQueue(0):setRate(args.rate)
--		mg.startSharedTask("doRecvCrossTraffic", txDev:getTxQueue(0))
	    mg.startTask("doRecvCrossTraffic", txDev:getTxQueue(0))
	--   --stats.startStatsTask{dev1, dev2}
	end
	stats.startStatsTask{txDev} -- , tx1Dev}
  --mg.startTask("initiateTimesyncs2s", txDev, txQueue, rxQueue, args.file, args.c)
  mg.waitForTasks()

end


function doRecvCrossTraffic(queue)
	local mem = memory.createMemPool(4096, function(buf)
		-- buf:getEthernetPacket():fill{
		-- 	ethSrc = queue,
		-- 	ethDst = ETHLOOP_SRC,
		-- 	ethType = 0x1234
		-- }
		buf:getUdpPacket():fill{
			ethSrc = queue,
			ethDst = ETHLOOP_SRC,
			ip4Src = SRC_IP,
			ip4Dst = DST_IP,
			udpSrc = SRC_PORT,
			udpDst = DST_PORT,
			pktLength = UDP_PKT_SIZE
		}
	end)
	local bufs = mem:bufArray()

	while mg.running() do
		bufs:alloc(UDP_PKT_SIZE)
		queue:send(bufs)
		-- mg.sleepMillis(100)
	end
end

function CrossTraffic(queue)
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethSrc = ETH_SRC,
			ethDst = ETHLOOP_DST,
			ethType = 0x1234
		}
	end)
	local bufs = mem:bufArray()

	while mg.running() do
		bufs:alloc(PKT_SIZE)
		queue:send(bufs)
	end
end


function initiateTimesyncs2s(txDev, txQueue, rxQueue, file, crossTraffic)
	local i = 0
	mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")
	local mem = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = ETHLOOP_SRC,
			ethDst = ETHLOOP_DST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	txDev:setPromisc(true)
	while mg.running() do
		i = i + 1
		startTimesyncs2s(i, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
		mg.sleepMillis(1000)
	end
	fp:close();
end


function startTimesyncs2s(count, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
	local maxWait = 15/1000

	rxDev = txDev
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()
	local txBufs = mem:bufArray(1)
	local rxBufs = mem.bufArray(1280)
	txBufs:alloc(PKT_SIZE)
	local txBuf = txBufs[1]
	--printf("Enabling Tx Timestamps..")
	txBuf:enableTimestamps()
	--buf:dump()

	--printf("Enabling timestamp for udp port %d\n", buf:getUdpPacket().udp:getDstPort())
  --while mg.running() do
	local timer = timer:new(maxWait)
  printf(red("Sending Timesync.."))
    --txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_GENDELAY_REQ)
	  --txQueue:send(txBufs)

	  txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_GENREQ)
		--txBuf:dump()
	  txQueue:send(txBufs)

		while timer:running() do
			--printf("Waiting")
			local rx = rxQueue:tryRecv(rxBufs, 1000)
			local timestampedPkt = rxDev:hasRxTimestamp()
				--printf("Response is timestamped")
			for i=1,rx do
				--printf("Packet Received")
				--printf("%d",i);
				local rxBuf = rxBufs[i]
				rxBuf:dump()
			end
		end
end

function syncClocks(dev1, dev2)
	local regs1 = dev1.timeRegisters
	local regs2 = dev2.timeRegisters
	if regs1[1] ~= regs2[1]
	or regs1[2] ~= regs2[2]
	or regs1[3] ~= regs2[3]
	or regs1[4] ~= regs2[4] then
		log:fatal("NICs incompatible, cannot sync clocks")
	end
	dpdkc.libmoon_sync_clocks(dev1.id, dev2.id, unpack(regs1))
	-- just to tell the driver that we are resetting the clock
	-- otherwise the cycle tracker becomes confused on long latencies
	dev1:resetTimeCounters()
	dev2:resetTimeCounters()
end
