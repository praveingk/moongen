

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



local HOST1	= "3c:fd:fe:b7:e7:f4"
local HOST2	= "3c:fd:fe:b7:e7:f5"
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
local PKT_SIZE	= 34
local UDP_PKT_SIZE = 1000

local avg_nic_delay = 0
local LINE_RATE = 10000000000 -- 10 Gbps
function configure(parser)
	parser:description("Generates a Timesync Request, and displays the Timestamp obtained from Master Clock")
	parser:argument("txDev", "Device to transmit/receive from."):convert(tonumber)
	parser:option("-c", "Start CrossTraffic"):default(0):convert(tonumber)
	parser:option("-d", "Start receiving CrossTraffic"):default(0):convert(tonumber)

	parser:option("-f --file", "Filename of the latency histogram."):default("timesync_delaywise.csv")
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
end

function master(args)
  txDev = device.config({port = args.txDev, rxQueues = 2, txQueues = 2})
	tx1Dev = device.config({port = 1, rxQueues = 2, txQueues = 2})
  device.waitForLinks()
	txQueue = txDev:getTxQueue(1)
	rxQueue = txDev:getRxQueue(1)

	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()

	-- Below is a mandatory and important command to put Timesync packets to RX Queue 1.
	rxQueue:filterL2Timestamps()
	printf("CrossTraffic=%d", args.c)

	if args.c == 1 then
		txDev:getTxQueue(0):setRate(args.rate)
		mg.startSharedTask("CrossTraffic", txDev:getTxQueue(0))
	end
	if args.d == 1 then
	 		printf("Starting to receive CrossTraffic")
			--device.waitForLinks()
	   	--tx1Dev:getTxQueue(1):setRate(args.rate)
	  	--mg.startTask("doRecvCrossTraffic", txDev:getTxQueue(0))
			mg.startTask("doRecvCrossTraffic", tx1Dev:getTxQueue(0))
	--   --stats.startStatsTask{dev1, dev2}
	end
   stats.startStatsTask{txDev}
   mg.startTask("initiateTimesync", txDev, txQueue, rxQueue, args.file, args.c)
   --mg.startSharedTask("initiateTimesyncMulti", txDev, tx1Dev:getTxQueue(0), tx1Dev:getRxQueue(0), args.file, args.c)
   --mg.startTask("initiateTimesyncMulti", txDev, txQueue, rxQueue, args.file, args.c)

  mg.waitForTasks()

end


function doRecvCrossTraffic(queue)
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethSrc = queue,
			ethDst = HOST1,
			ethType = 0x1234
		}
		-- buf:getUdpPacket():fill{
		-- 	ethSrc = queue,
		-- 	ethDst = HOST1,
		-- 	ip4Src = SRC_IP,
		-- 	ip4Dst = DST_IP,
		-- 	udpSrc = SRC_PORT,
		-- 	udpDst = DST_PORT,
		-- 	pktLength = UDP
		-- }
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
			ethDst = HOST2,
			ethType = 0x1234
		}
	end)
	local bufs = mem:bufArray()

	while mg.running() do
		bufs:alloc(PKT_SIZE)
		queue:send(bufs)
	end
end

function do_send_crosstraffic(queue, crossTraffic)
	--printf("Sending Bursts")
	local total_pkts = 0
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethSrc = ETH_SRC,
			ethDst = BCAST,
			ethType = 0x1234
		}
	end)
	if (crossTraffic == 1) then
		total_pkts = 2000
	end
	local bufs = mem:bufArray()
	for i=1, total_pkts,1 do
		bufs:alloc(PKT_SIZE)

		queue:send(bufs)
	end
end

function initiateTimesync(txDev, txQueue, rxQueue, file, crossTraffic)
	local i = 0
	mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")
	local mem = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST1,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	syncClocks(txDev, txDev)
	while mg.running() do
		i = i + 1
		startTimesyncProfile(i, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
		mg.sleepMillis(10)
		--mg.sleepMillis(1000)
	end
	fp:close();
end

function initiateTimesyncMulti(txDev, txQueue, rxQueue, file, crossTraffic)
	local i = 0
	mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")
	local mem1 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST1,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem2 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST2,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem3 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST3,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem4 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST4,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem5 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST5,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem6 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST6,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem7 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST7,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem8 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST8,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)

	local mem9 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = HOST9,
			ethDst = BCAST,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)

	syncClocks(txDev, txDev)
	while mg.running() do
		i = i + 1
		--startTimesync(i, mem1, txDev, txQueue, rxQueue, fp, crossTraffic)
		startTimesync2(i, mem3, txDev, txQueue, rxQueue, fp, crossTraffic)
		-- -- -- --  --startTimesync(i, mem3, txDev, txQueue, rxQueue, fp, crossTraffic)
		startTimesync2(i, mem4, txDev, txQueue, rxQueue, rxQ, fp, crossTraffic)
		startTimesync2(i, mem5, txDev, txQueue, rxQueue, rxQ, fp, crossTraffic)
		startTimesync2(i, mem6, txDev, txQueue, rxQueue, rxQ, fp, crossTraffic)
		startTimesync2(i, mem7, txDev, txQueue, rxQueue, rxQ, fp, crossTraffic)
		startTimesync2(i, mem8, txDev, txQueue, rxQueue, rxQ, fp, crossTraffic)
		startTimesync2(i, mem9, txDev, txQueue, rxQueue, rxQ, fp, crossTraffic)

		mg.sleepMillis(1)
	end
	fp:close();
end


function startTimesyncProfile(count, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
	local maxWait = 15/1000
	rxDev = txDev
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()
	local txBufs = mem:bufArray(1)
	local rxBufs = mem.bufArray(1)
	txBufs:alloc(PKT_SIZE)
	local txBuf = txBufs[1]
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
	local elapsedTs
	local reference_hi
	local reference_lo
	local curr_rate
	local max_ns = 1000000000

  printf(red("Sending Timesync.."))
	txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_DELAY_REQ)
	rxDev:clearTimestamps()
	txQueue:send(txBufs)
	local txDelayTs = txQueue:getTimestamp(500)

	txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_REQ)
	rxDev:clearTimestamps()
	txQueue:send(txBufs)
	local txReqTs = txQueue:getTimestamp(500)

	local timer = timer:new(maxWait)
	while timer:running() do
		local rx = rxQueue:tryRecv(rxBufs, 1000)
		local timestampedPkt = rxDev:hasRxTimestamp()
		if not timestampedPkt then
			rxBufs:freeAll()
		else
			for i=1,rx do
				local rxBuf = rxBufs[i]
				local rxPkt = rxBuf:getTimesyncPacket()
				if (rxPkt.eth:getType() ~= 0x88f7) then
					rxQueue:getTimestamp(nil, timesync)
				else
					if (rxPkt.timesync:getCommand() == proto.timesync.TYPE_RES) then
						rxTs = rxQueue:getTimestamp(nil, timesync)
						printf(green(rxPkt.timesync:getString()))
						if (rxTs == nil) then
							break
						end
						lat = rxTs - txReqTs
						lat_2probe = rxTs - txDelayTs
						clientDelay_2probe = txReqTs - txDelayTs
						reference_lo = rxPkt.timesync:getReference_ts_lo()
						curr_rate = rxPkt.timesync:getDelta()
						elapsedTs = rxPkt.timesync:getIgTs()
						egTs = rxPkt.timesync:getEgTs()
						switchDelay = rxPkt.timesync:getEgTs() - rxPkt.timesync:getIgTs()
						switchReqDelay = rxPkt.timesync:getIgTs() - rxPkt.timesync:getMacTs();
						rxBufs:freeAll()
						break
					end
					if (rxPkt.timesync:getCommand() == proto.timesync.TYPE_CAPTURE_TX) then
							local capture_tx = rxPkt.timesync:getReference_ts_hi()
							if (egTs == nil) then
								break
							end
							local respEgressDelay = capture_tx - egTs
							local nic_wire_delay = lat - (switchReqDelay + switchDelay + respEgressDelay)
							printf(green(rxPkt.timesync:getString()))
							local rate_percent = (curr_rate*8)/LINE_RATE
							printf(green("Switch Request Delay = %d ns", switchReqDelay))
							printf(green("Switch Queing Delay = %d ns", switchDelay))
							printf(green("Switch Response Egress Delay =%d ns", respEgressDelay))
							printf("---------------------------------");
							printf(green("Latency = %d ns", lat))
							printf(green("Unaccounted delay = %d ns", nic_wire_delay))
							printf(green("Current Traffic Rate = %d bps %f", curr_rate, rate_percent))
							printf("---------------------------------")
							if (rate_percent < 0.0001) then
								if (avg_nic_delay == 0) then
									avg_nic_delay = nic_wire_delay
								else
									avg_nic_delay = (avg_nic_delay + nic_wire_delay)/2
								end
							end
							printf(green("Avg NIC Delay = %d", avg_nic_delay))
							printf("---------------------------------")
							if (switchReqDelay >= 0) then
								if (count > 1000) then
									printf("Not Logging!")
								else
									fp:write(("%d, %d, %d, %d, %d, %d\n"):format(count, switchReqDelay, switchDelay, respEgressDelay, nic_wire_delay, lat))
								end
							end
							rxBufs:freeAll()
							return
					end
				end
			end
		end
	end
end


function startTimesync2(count, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
	local maxWait = 1/1000

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
	local elapsedTs
	local reference_hi
	local reference_lo
	local max_ns = 1000000000

  printf(red("Sending Timesync.."))
	txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_DELAY_REQ)
	rxDev:clearTimestamps()
	txQueue:send(txBufs)
	local txDelayTs = txQueue:getTimestamp(500)

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
				--rxPkt:dump()
				if (rxPkt.eth:getType() ~= 0x88f7) then
					--printf("Cross traffic %X", rxPkt.eth:getType());
					rxQueue:getTimestamp(nil, timesync)
					--break;--continue;
				else
					if (rxPkt.timesync:getCommand() == proto.timesync.TYPE_RES) then
						--rxPkt:dump()
						rxTs = rxQueue:getTimestamp(nil, timesync)
						printf(green(rxPkt.timesync:getString()))
						--printf("tx = %u", txReqTs)
						--printf("rxts = %u", rxTs);
						if (rxTs == nil) then
							break
						end
						lat = rxTs - txReqTs
						lat_2probe = rxTs - txDelayTs
						clientDelay_2probe = txReqTs - txDelayTs
						reference_lo = rxPkt.timesync:getReference_ts_lo()
						switchDelay_2probe = rxPkt.timesync:getDelta()
						elapsedTs = rxPkt.timesync:getIgTs()
						egTs = rxPkt.timesync:getEgTs()
						switchDelay = rxPkt.timesync:getEgTs() - rxPkt.timesync:getIgTs()
						switchReqDelay = rxPkt.timesync:getIgTs() - rxPkt.timesync:getMacTs();
						upstreamOffset = switchDelay_2probe - clientDelay_2probe
						upstreamQueingDelay = switchDelay_2probe	--(switchDelay_2probe - clientDelay_2probe) + clientDelay_2probe
						rxBufs:freeAll()
						break
					end
					if (rxPkt.timesync:getCommand() == proto.timesync.TYPE_CAPTURE_TX) then
							local capture_tx = rxPkt.timesync:getReference_ts_hi()
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
							printf(green("Latency(2probe) for delay = %d ns", lat_2probe))
							printf(green("Latency(2probe) = %d ns", lat_2probe - upstreamQueingDelay))
							printf(green("Static Wire delay = %d ns", 2*wire_delay))
							printf(green("Unaccounted delay = %d ns", lat - (switchDelay + respEgressDelay + (2 * wire_delay))))
							printf("---------------------------------");
							if (upstreamQueingDelay < clientDelay_2probe ) then
								upstreamQueingDelay = clientDelay_2probe
							end
							if (switchReqDelay < 0) then
								switchReqDelay = -switchReqDelay;
							end
							--printf(green("pstream offset = %d ns", upstreamOffset))
							--fp:write("%d, %d\n", count, upstreamQueingDelay)
							local replydelay_ptp = lat /2
							local replydelay_switchdelaybased = (lat - switchDelay - switchReqDelay)/2 + switchDelay + wire_delay
							--local replydelay_2probe = (lat_2probe - switchDelay - upstreamQueingDelay)/2 + switchDelay
							--local replydelay_2probe_simple = lat_2probe - upstreamQueingDelay
							--fp:write(("%d, %d, %d, %d, %d, %d, %d, %d\n"):format(count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchReqDelay, switchDelay))
							local calc_time_lo = reference_lo + (elapsedTs % max_ns) + (replydelay_switchdelaybased % max_ns);
							local calc_time_lo_ptp = reference_lo + (elapsedTs % max_ns) + (replydelay_ptp % max_ns);
							--local calc_time_lo_1wbased = reference_lo + (elapsedTs % max_ns) + (replydelay_ptp % max_ns);
							printf(green("txReqTs = %d ns", txReqTs))
							printf(green("calc_time_lo = %d ns", calc_time_lo))
							printf(green("calc_time_lo_ptp = %d ns", calc_time_lo_ptp))

							fp:write(("%d, %d, %d, %d\n"):format(count, txReqTs, calc_time_lo, calc_time_lo_ptp))
							if (switchReqDelay >= 0) then
								if (count > 100) then
									printf("Not Logging!")
								else
									fp:write(("%d, %d, %d, %d, %d, %d \n"):format(count, switchReqDelay, switchDelay, respEgressDelay, 2 * wire_delay , lat - (switchDelay + respEgressDelay + (2 * wire_delay))))
								end
							end
							rxBufs:freeAll()
							return
					end
				end
			end
		end
	end
end

function startTimesyncDummy(count, mem, txDev, txQueue, rxQueue, fp, crossTraffic)
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
	local elapsedTs
	local reference_hi
	local reference_lo
	local max_ns = 1000000000

  --printf(red("Sending Timesync.."))
	txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_DELAY_REQ)
	rxDev:clearTimestamps()
	txQueue:send(txBufs)
	local txDelayTs = txQueue:getTimestamp(500)

	txBuf:getTimesyncPacket().timesync:setCommand(proto.timesync.TYPE_REQ)
	rxDev:clearTimestamps()
	txQueue:send(txBufs)
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
