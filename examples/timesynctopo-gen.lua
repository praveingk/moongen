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
local ETHLOOP_DST = "a0:00:00:00:00:0a"

local ETH_SRC	= "3c:fd:fe:b7:e7:f4"
local ETH_SRC1	= "3c:fd:fe:b7:e7:f5"
local BCAST = "FF:FF:FF:FF:FF:FF"
local DUMMY_DST = "3c:fd:fe:b7:e7:f9"

local SWITCH1	= "10:00:00:00:00:01"
local SWITCH2	= "20:00:00:00:00:02"


local SWITCH3_PORT1	= "30:00:00:10:00:03"
local SWITCH3_PORT2	= "30:00:00:20:00:03"

local SWITCH4_PORT1	= "40:00:00:10:00:04"
local SWITCH4_PORT2	= "40:00:00:20:00:04"


local SWITCHMASTER_PORT1 = "a0:00:00:10:00:0a"
local SWITCHMASTER_PORT2 = "a0:00:00:20:00:0a"

local TYPE_TS = 0x1235
local PKT_SIZE	= 34
local UDP_PKT_SIZE = 1000

function configure(parser)
	parser:description("Generates a Timesync Request, and displays the Timestamp obtained from Master Clock")
	parser:argument("txDev", "Device to transmit/receive from."):convert(tonumber)
	parser:option("-c", "Start CrossTraffic"):default(0):convert(tonumber)
	parser:option("-d", "Start receiving CrossTraffic"):default(0):convert(tonumber)
	parser:option("-s", "Switch to Switch"):default(0):convert(tonumber)
	parser:option("-p", "Switch to Host"):default(0):convert(tonumber)

	parser:option("-f --file", "Filename of the latency histogram."):default("timesync.csv")
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
end

function master(args)
  txDev = device.config({port = args.txDev, rxQueues = 2, txQueues = 2})
  device.waitForLinks()
	txQueue = txDev:getTxQueue(1)
	rxQueue = txDev:getRxQueue(0)

	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()

	-- Below is a mandatory and important command to put Timesync packets to RX Queue 1.
	rxQueue:filterL2Timestamps()
	printf("CrossTraffic=%d", args.c)

	if args.c == 1 then
		mg.startSharedTask("CrossTraffic", txDev:getTxQueue(0))
	end
	if args.d == 1 then
	 		printf("Starting to receive CrossTraffic")

			--device.waitForLinks()
	   	txDev:getTxQueue(0):setRate(args.rate)
			mg.startSharedTask("doRecvCrossTraffic", txDev:getTxQueue(0))
	--   --stats.startStatsTask{dev1, dev2}
	end
	--stats.startStatsTask{txDev, tx1Dev}
	if args.s == 1 then
  	mg.startTask("InitiateTopoTimesync", txDev, txQueue, rxQueue, args.file)
		--initiateTimesyncSwitch3(txDev, txQueue, rxQueue, args.file)
		-- mg.sleepMillis(200)
		-- initiateTimesyncSwitch4(txDev, txQueue, rxQueue, args.file)
		-- mg.sleepMillis(200)
		-- initiateTimesyncSwitch2(txDev, txQueue, rxQueue, args.file)
		-- mg.sleepMillis(200)
		-- initiateTimesyncSwitch1(txDev, txQueue, rxQueue, args.file)
		-- mg.sleepMillis(200)

	end
	if args.p == 1 then
		mg.startTask("initiateTimesync", txDev, txQueue, rxQueue, args.file, args.c)
	end
  mg.waitForTasks()

end


function doRecvCrossTraffic(queue)
	local mem = memory.createMemPool(function(buf)
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
			pktLength = UDP
		}
	end)
	local bufs = mem:bufArray()

	while mg.running() do
		bufs:alloc(PKT_SIZE)
		queue:send(bufs)
		--mg.sleepMillis(100)
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

function InitiateTopoTimesync(txDev, txQueue, rxQueue, file)
  local mem1 = memory.createMemPool(function(buf)
    buf:getTimesyncPacket():fill{
      ethSrc = SWITCH1,
      ethDst = SWITCH3_PORT1,
      ethType = proto.eth.TYPE_TS,
      command = proto.timesync.TYPE_REQ,
    }
  end)
  local mem2 = memory.createMemPool(function(buf)
    buf:getTimesyncPacket():fill{
      ethSrc = SWITCH2,
      ethDst = SWITCH4_PORT1,
      ethType = proto.eth.TYPE_TS,
      command = proto.timesync.TYPE_REQ,
    }
  end)
  local mem3 = memory.createMemPool(function(buf)
    buf:getTimesyncPacket():fill{
      ethSrc = SWITCH3_PORT2,
      ethDst = SWITCHMASTER_PORT1,
      ethType = proto.eth.TYPE_TS,
      command = proto.timesync.TYPE_REQ,
    }
  end)
  local mem4 = memory.createMemPool(function(buf)
    buf:getTimesyncPacket():fill{
      ethSrc = SWITCH4_PORT2,
      ethDst = SWITCHMASTER_PORT2,
      ethType = proto.eth.TYPE_TS,
      command = proto.timesync.TYPE_REQ,
    }
  end)
	while mg.running() do
		initiateTimesyncSwitch3(txDev, txQueue, rxQueue, file, mem3)
		mg.sleepMillis(10)
		initiateTimesyncSwitch4(txDev, txQueue, rxQueue, file, mem4)
		mg.sleepMillis(10)
		initiateTimesyncSwitch2(txDev, txQueue, rxQueue, file, mem2)
		mg.sleepMillis(10)
		initiateTimesyncSwitch1(txDev, txQueue, rxQueue, file, mem1)
		mg.sleepMillis(10)
	end
end
function initiateTimesyncSwitch1(txDev, txQueue, rxQueue, file, mem)
	local i = 0
	--mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")

	txDev:setPromisc(true)
	--while mg.running() do
		i = i + 1
		startTimesyncs2s(i, mem, txDev, txQueue, rxQueue, fp)
		--mg.sleepMillis(10)
	--end
	fp:close();
end

function initiateTimesyncSwitch2(txDev, txQueue, rxQueue, file, mem)
	local i = 0
	--mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")

	txDev:setPromisc(true)
	--while mg.running() do
		i = i + 1
		startTimesyncs2s(i, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
		--mg.sleepMillis(10)
	--end
	fp:close();
end

function initiateTimesyncSwitch3(txDev, txQueue, rxQueue, file, mem)
	local i = 0
	--mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")

	txDev:setPromisc(true)
	--while mg.running() do
		i = i + 1
		startTimesyncs2s(i, mem, txDev, txQueue, rxQueue, fp)
		--mg.sleepMillis(2000)
	--end
	fp:close();
end

function initiateTimesyncSwitch4(txDev, txQueue, rxQueue, file, mem)
	local i = 0
	--mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")

	txDev:setPromisc(true)
	--while mg.running() do
		i = i + 1
		startTimesyncs2s(i, mem, txDev, txQueue, rxQueue, fp)
		--mg.sleepMillis(2000)
	--end
	fp:close();
end

function startTimesyncs2s(count, mem, txDev, txQueue, rxQueue, fp)
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
	-- txBuf:dump()

	--printf("Enabling timestamp for udp port %d\n", buf:getUdpPacket().udp:getDstPort())
  --while mg.running() do
	local timer = timer:new(maxWait)
  printf(red("Sending Timesync.."))
    -- txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_GENDELAY_REQ)
	  -- txQueue:send(txBufs)

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
				-- local rxBuf = rxBufs[i]
				-- rxBuf:dump()
			end
		end
end


function initiateTimesync(txDev, txQueue, rxQueue, file, crossTraffic)
	local i = 0
	mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")
	local mem = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = txQueue,
			ethDst = SWITCH1,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	syncClocks(txDev, txDev)
	while mg.running() do
		i = i + 1
		startTimesync(i, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
		mg.sleepMillis(2000)
	end
	fp:close();
end


function startTimesync(count, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
	local maxWait = 15/1000

	rxDev = txDev
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()
	local txBufs = mem:bufArray(1)
	local rxBufs = mem.bufArray(1)
	txBufs:alloc(PKT_SIZE)
	local txBuf = txBufs[1]
	--printf("Enabling Tx Timestamps..")
	txBuf:enableTimestamps()

	local lat
	local lat_2probe
	local clientDelay_2probe
	local switchDelay_2probe
	local switchDelay
	local switchReqDelay
	local upstreamOffset
	local upstreamQueingDelay
	local rxTs
	local egTs
	local macTs
	local elapsedTs
	local reference_hi
	local reference_lo
	local max_ns = 1000000000

  printf(red("Sending Timesync.."))
	-- txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_DELAY_REQ)
	-- rxDev:clearTimestamps()
	-- txQueue:send(txBufs)
	-- local txDelayTs = txQueue:getTimestamp(500)

	txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_REQ)
	rxDev:clearTimestamps()
	txQueue:send(txBufs)
	local txReqTs = txQueue:getTimestamp(500)

	local timer = timer:new(maxWait)
	while timer:running() do
		--printf("Waiting")
		local rx = rxQueue:tryRecv(rxBufs, 1000)
		--printf("Total packets reev = %d\n", rx)
		local timestampedPkt = rxDev:hasRxTimestamp()
		if not timestampedPkt then
			--printf("Response is not timestamped")
			rxBufs:freeAll()
		else
			--printf("Response is timestamped")
			for i=1,rx do
				--printf("Packet %d",i);
				local rxBuf = rxBufs[i]
				--rxBuf:dump()
				local rxPkt = rxBuf:getTimesyncPacket()
				rxPkt:dump()
				if (rxPkt.eth:getType() ~= 0x88f7) then
					--printf("Cross traffic %X", rxPkt.eth:getType());
					rxQueue:getTimestamp(nil, timesync)
					--break;--continue;
				else
					if (rxPkt.timesync:getCommand() == proto.timesync.TYPE_RES) then
						rxPkt:dump()
						rxTs = rxQueue:getTimestamp(nil, timesync)
						printf(green(rxPkt.timesync:getString()))
						printf("tx = %u", txReqTs)
						printf("rxts = %u", rxTs);
						lat = rxTs - txReqTs
						reference_lo = rxPkt.timesync:getReference_ts_lo()
						switchDelay_2probe = rxPkt.timesync:getDelta()
						elapsedTs = rxPkt.timesync:getIgTs()
						egTs = rxPkt.timesync:getEgTs()
						macTs = rxPkt.time:getMacTs();
						switchDelay = rxPkt.timesync:getEgTs() - rxPkt.timesync:getIgTs()
						switchReqDelay = rxPkt.timesync:getIgTs() - rxPkt.timesync:getMacTs();
						rxBufs:freeAll()
						break
					end
				end
			end
		end
	end
	mg.sleepMillis(300)
	printf(red("Sending CaptureTx.."))

	txBuf:getTimesyncPacket().timesync:setMagic(proto.timesync.TYPE_CAPTURE_TX)
	txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_CAPTURE_TX)
	txQueue:send(txBufs)
	--local timea = timer:new(maxWait)
	--while timer:running() do
		--printf("Waiting")
		local rx = rxQueue:tryRecv(rxBufs, 1000)
		--printf("Total packets reev = %d\n", rx)
			--printf("Response is timestamped")
		for i=1,rx do
				--printf("Packet %d",i);
				local rxBuf = rxBufs[i]
				local rxPkt = rxBuf:getTimesyncPacket()
				if (rxPkt.eth:getType() ~= 0x88f7) then
					rxQueue:getTimestamp(nil, timesync)
				else
					if (rxPkt.timesync:getCommand() == proto.timesync.TYPE_CAPTURE_TX) then
							local capture_tx = rxPkt.timesync:getDelta()
							--rxPkt:dump()
							if (egTs == nil) then
								break
							end
							local respEgressDelay = capture_tx - egTs
							local wire_delay = 75;
							printf(green(rxPkt.timesync:getString()))
							--printf("capture Tx = %d", capture_tx)
							--printf(green("Client Offset(2-probe) = %d ns", clientDelay_2probe))
							--printf(green("Switch Offset(2-probe) = %d ns", switchDelay_2probe))
							printf(green("Switch Request Delay = %d ns", switchReqDelay))
							printf(green("Switch Queing Delay = %d ns", switchDelay))
							printf(green("Switch Response Egress Delay =%d ns", respEgressDelay))
							--printf(green("Upstream Queing Delay = %d ns", upstreamOffset))
							printf("---------------------------------");
							printf(green("Latency = %d ns", lat))
							printf(green("Static Wire delay = %d ns", 2*wire_delay))
							printf(green("Unaccounted delay = %d ns", lat - (switchDelay + respEgressDelay + (2 * wire_delay))))
							printf("---------------------------------");



							--printf(green("pstream offset = %d ns", upstreamOffset))
							--fp:write("%d, %d\n", count, upstreamQueingDelay)
							local replydelay_ptp = lat /2
							local replydelay_switchdelaybased = (lat - switchDelay - switchReqDelay)/2 + switchDelay + wire_delay
							local replydelay_ptp4 = (lat - (capture_tx - macTs))/2
							--local replydelay_2probe = (lat_2probe - switchDelay - upstreamQueingDelay)/2 + switchDelay
							--local replydelay_2probe_simple = lat_2probe - upstreamQueingDelay
							printf("replydelay_ptp4 = %d ns", replydelay_ptp4)
							--fp:write(("%d, %d, %d, %d, %d, %d, %d, %d\n"):format(count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchReqDelay, switchDelay))
							local calc_time_lo = reference_lo + (elapsedTs % max_ns) + (replydelay_switchdelaybased % max_ns);
							local calc_time_lo_ptp = reference_lo + (elapsedTs % max_ns) + (replydelay_ptp % max_ns);
							local calc_time_lo_ptp4 = reference_lo + (capture_tx) + (replydelay_ptp4 % max_ns)
							--local calc_time_lo_1wbased = reference_lo + (elapsedTs % max_ns) + (replydelay_ptp % max_ns);
							printf(green("txReqTs = %d ns", txReqTs))
							printf(green("calc_time_lo = %d ns", calc_time_lo))
							printf(green("calc_time_lo_ptp = %d ns", calc_time_lo_ptp))
							printf(green("calc_time_lo_ptp4 = %d ns", calc_time_lo_ptp4))

							fp:write(("%d, %d, %d\n"):format(count, txReqTs, calc_time_lo_ptp4))
							-- if (switchReqDelay >= 0) then
							-- 	if (count > 100) then
							-- 		printf("Not Logging!")
							-- 	else
							-- 		fp:write(("%d, %d, %d, %d, %d, %d \n"):format(count, switchReqDelay, switchDelay, respEgressDelay, 2 * wire_delay , lat - (switchDelay + respEgressDelay + (2 * wire_delay))))
							-- 	end
							-- end
							rxBufs:freeAll()
							break
					end
				end
	--	end
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
