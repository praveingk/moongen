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



local ETH_SRC	= "3c:fd:fe:b7:e7:f4"
local ETH_SRC1	= "3c:fd:fe:b7:e7:f5"

local SWITCH1	= "10:00:00:00:00:01"
local SWITCH2	= "20:00:00:00:00:02"


local BCAST = "FF:FF:FF:FF:FF:FF"
local DUMMY_DST = "3c:fd:fe:b7:e7:f9"
local TYPE_TS = 0x1235
local PKT_SIZE	= 34
local UDP_PKT_SIZE = 1000

function configure(parser)
	parser:description("Generates a Timesync Request, and displays the Timestamp obtained from Master Clock")
	parser:argument("tx1Dev", "Device to transmit/receive from."):convert(tonumber)
	parser:argument("tx2Dev", "Device to transmit/receive from."):convert(tonumber)
	parser:option("-c", "Start CrossTraffic"):default(0):convert(tonumber)
	parser:option("-d", "Start receiving CrossTraffic"):default(0):convert(tonumber)

	parser:option("-f --file", "Filename of the latency histogram."):default("timesync_multiport.csv")
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
end

function master(args)
  tx1Dev = device.config({port = args.tx1Dev, rxQueues = 2, txQueues = 2})
	tx2Dev = device.config({port = args.tx2Dev, rxQueues = 2, txQueues = 2})
  device.waitForLinks()
	tx1Queue = tx1Dev:getTxQueue(1)
	rx1Queue = tx1Dev:getRxQueue(1)

	tx1Queue:enableTimestamps()
	rx1Queue:enableTimestamps()

	tx2Queue = tx2Dev:getTxQueue(1)
	rx2Queue = tx2Dev:getRxQueue(1)

	tx2Queue:enableTimestamps()
	rx2Queue:enableTimestamps()
	-- Below is a mandatory and important command to put Timesync packets to RX Queue 1.
	rx1Queue:filterL2Timestamps()
	rx2Queue:filterL2Timestamps()

	if args.c == 1 then
		--tx1Dev:getTxQueue(0):setRate(8000)
		mg.startTask("CrossTraffic", tx1Dev:getTxQueue(0))
	end
	--stats.startStatsTask{txDev, tx1Dev}
	stats.startStatsTask{tx1Dev, tx2Dev}

  mg.startTask("initiateTimesync", tx1Dev, tx1Queue, rx1Queue, tx2Dev, tx2Queue, rx2Queue, args.file)
  mg.waitForTasks()

end

function CrossTraffic(queue)
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethSrc = queue,
			ethDst = SWITCH1,
			ethType = 0x1234
		}
		-- buf:getUdpPacket():fill{
		-- 	ethSrc = queue,
		-- 	ethDst = SWITCH1,
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
	end
end


function initiateTimesync(tx1Dev, tx1Queue, rx1Queue, tx2Dev, tx2Queue, rx2Queue, file)
	local i = 0
	mg.sleepMillis(1000)
	fp = io.open(file, "w")
	fp:write("count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchDelay\n")
	local mem1 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = tx1Queue,
			ethDst = BCAST,--SWITCH1,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem2 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = tx2Queue,
			ethDst = BCAST,--SWITCH2,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	while mg.running() do
		i = i + 1
		syncClocks(tx1Dev, tx2Dev)
		calc_time1_dptp, x1, y1 = startTimesync(i, mem1, tx1Dev, tx1Queue, rx1Queue, fp)
		mg.sleepMillis(1)
		calc_time2_dptp, x2, y2 = startTimesync(i, mem2, tx2Dev, tx2Queue, rx2Queue, fp)
		drift_factor_avg = 0.000022755
		drift_factor_median = 0.000022745

		if (x1 ~= nil and x2~=nil) then
			local diff_time = x2-x1
			local drift_avg = diff_time * drift_factor_avg
			local drift_mean = diff_time * drift_factor_median
			local drift_now = (y2 - y1) - (x2 - x1)

			printf("%d-%d(%d) %d-%d(%d)", y1, y2,y2-y1, x1, x2, x2-x1)
			printf("Drift now = %d", drift_now)
			-- printf("%u:%u", calc_time1_dptp + drift_avg,  calc_time2_dptp)
			-- printf("%u:%u", calc_time1_dptp + drift_mean, calc_time2_dptp)
			printf("%u:%u", calc_time1_dptp + drift_now,  calc_time2_dptp)

			if (calc_time1_dptp > 0 and calc_time2_dptp > 0) then
				--printf("%d, %d",calc_time2_dptp - calc_time1_dptp - drift_avg, calc_time2_dptp - calc_time1_dptp - drift_mean)
				printf("%d, %d",calc_time2_dptp - calc_time1_dptp - drift_now, calc_time2_dptp - calc_time1_dptp)
				fp:write(("%d, %d\n"):format(calc_time2_dptp - calc_time1_dptp - drift_now, calc_time2_dptp - calc_time1_dptp))

				--fp:write(("%d, %d\n"):format(calc_time2_ptp - calc_time1_ptp - drift_avg, calc_time2_ptp - calc_time1_ptp - drift_mean, calc_time2_sw - calc_time1_sw - drift_avg, calc_time2_sw - calc_time1_sw - drift_mean))
			end
		end
		mg.sleepMillis(1000)
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
						macTs = rxPkt.timesync:getMacTs()
						switchDelay = rxPkt.timesync:getEgTs() - rxPkt.timesync:getIgTs()
						switchReqDelay = rxPkt.timesync:getIgTs() - rxPkt.timesync:getMacTs();
						upstreamOffset = switchDelay_2probe - clientDelay_2probe
						upstreamQueingDelay = switchDelay_2probe	--(switchDelay_2probe - clientDelay_2probe) + clientDelay_2probe
						rxBufs:freeAll()
						break
					end
					if (rxPkt.timesync:getCommand() == proto.timesync.TYPE_CAPTURE_TX) then
							--local capture_tx = rxPkt.timesync:getIgTs()
							local capture_tx = rxPkt.timesync:getReference_ts_hi()
							--rxPkt:dump()
							if (egTs == nil) then
								return -1,-1,-1
							end
							local respEgressDelay = capture_tx - egTs
							local replydelay_dptp = (lat - (capture_tx - macTs))/2

							printf(green(rxPkt.timesync:getString()))
							printf("---------------------------------");
							printf(green("Device = %d", txDev.id))
							printf(green("Switch Request Delay = %d ns", switchReqDelay))
							printf(green("Switch Queing Delay = %d ns", switchDelay))
							printf(green("Switch Response Egress Delay =%d ns", respEgressDelay))
							printf("---------------------------------");
							printf(green("Latency = %d ns", lat))
							printf(green("Unaccounted delay = %d ns", lat - (switchDelay + respEgressDelay)))
							printf(green("Reply delay       = %d ns", replydelay_dptp))
							printf("---------------------------------");

							local calc_time_lo_dptp = reference_lo + (capture_tx % max_ns) + (replydelay_dptp % max_ns);

							printf(green("rxReqTs = %d ns", txReqTs))
							printf(green("capture_tx = %d ns", capture_tx))

							printf(green("calc_time_lo_dptp = %d ns", calc_time_lo_dptp))

							local calc_time_igref_dptp = calc_time_lo_dptp - rxTs
							rxBufs:freeAll()
							fp:write(("%d, %d, %d\n"):format(count, txReqTs, calc_time_lo_dptp))
							return calc_time_igref_dptp, rxTs, capture_tx
					end
				end
			end
		end
	end
	return -1,-1,-1
end

function startTimesyncOld(count, mem, txDev, txQueue, rxQueue, fp)
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
						lat = rxTs - txReqTs
						--lat_2probe = rxTs - txDelayTs
						--clientDelay_2probe = txReqTs - txDelayTs
						reference_lo = rxPkt.timesync:getReference_ts_lo()
						switchDelay_2probe = rxPkt.timesync:getDelta()
						elapsedTs = rxPkt.timesync:getIgTs()
						egTs = rxPkt.timesync:getEgTs()
						macTs = rxPkt.timesync:getMacTs()
						switchDelay = rxPkt.timesync:getEgTs() - rxPkt.timesync:getIgTs()
						switchReqDelay = rxPkt.timesync:getIgTs() - rxPkt.timesync:getMacTs();
						--upstreamOffset = switchDelay_2probe - clientDelay_2probe
						--upstreamQueingDelay = switchDelay_2probe	--(switchDelay_2probe - clientDelay_2probe) + clientDelay_2probe
						rxBufs:freeAll()
						break
					end
				end
			end
		end
	end
	mg.sleepMillis(200)

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
							--local capture_tx = rxPkt.timesync:getIgTs()
							local capture_tx = rxPkt.timesync:getDelta()
							--rxPkt:dump()
							if (egTs == nil) then
								return -1,-1,-1,-1
							end
							local respEgressDelay = capture_tx - egTs
							local wire_delay = 65;
							local offset = math.random(0, 12)
							wire_delay = wire_delay + offset
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
							--printf(green("Latency(2probe) for delay = %d ns", lat_2probe))
							--printf(green("Latency(2probe) = %d ns", lat_2probe - upstreamQueingDelay))
							printf(green("Static Wire delay = %d ns", 2*wire_delay))
							printf(green("Unaccounted delay = %d ns", lat - (switchDelay + respEgressDelay + (2 * wire_delay))))
							printf("---------------------------------");
							-- if (upstreamQueingDelay < clientDelay_2probe ) then
							-- 	upstreamQueingDelay = clientDelay_2probe
							-- end
							-- if (switchReqDelay < 0) then
							-- 	switchReqDelay = -switchReqDelay;
							-- end
							--printf(green("pstream offset = %d ns", upstreamOffset))
							--fp:write("%d, %d\n", count, upstreamQueingDelay)
							local replydelay_ptp = lat/2
							local replydelay_switchdelaybased = switchDelay + respEgressDelay + wire_delay
							local replydelay_ptp4 = (lat - (capture_tx - macTs))/2
							--local replydelay_2probe = (lat_2probe - switchDelay - upstreamQueingDelay)/2 + switchDelay
							--local replydelay_2probe_simple = lat_2probe - upstreamQueingDelay
							--fp:write(("%d, %d, %d, %d, %d, %d, %d, %d\n"):format(count, replydelay_ntp, replydelay_switchdelaybased, replydelay_2probe, replydelay_2probe_simple, upstreamOffset, switchReqDelay, switchDelay))
							printf(green("replydelay_ptp = %d ns", replydelay_ptp))
							printf(green("replydelay_switchdelaybased = %d ns", replydelay_switchdelaybased))
							printf(green("replydelay_ptp4 = %d ns", replydelay_ptp4))

							local calc_time_lo = reference_lo + (elapsedTs % max_ns) + (replydelay_switchdelaybased % max_ns);
							local calc_time_lo_ptp4 = reference_lo + (capture_tx % max_ns) + (replydelay_ptp4 % max_ns);
							local calc_time_lo_ptp = reference_lo + (elapsedTs % max_ns) + (replydelay_ptp % max_ns);
							--local calc_time_lo_1wbased = reference_lo + (elapsedTs % max_ns) + (replydelay_ptp % max_ns);


							printf(green("rxReqTs = %d ns", txReqTs))
							printf(green("calc_time_lo = %d ns", calc_time_lo))
							printf(green("calc_time_lo_ptp = %d ns", calc_time_lo_ptp))
							printf(green("calc_time_lo_ptp4 = %d ns", calc_time_lo_ptp4))

							local calc_time_igref_sw = calc_time_lo - rxTs --reference_lo + (replydelay_switchdelaybased % max_ns) -- switchReqDelay
							local calc_time_igref_ptp = calc_time_lo_ptp - rxTs --reference_lo + (replydelay_ptp % max_ns) -- switchReqDelay
							local calc_time_igref_ptp4 = calc_time_lo_ptp4 - rxTs
							rxBufs:freeAll()
							fp:write(("%d, %d, %d, %d\n"):format(count, txReqTs, calc_time_lo, calc_time_lo_ptp))
							return calc_time_igref_ptp4, calc_time_igref_ptp, rxTs, capture_tx
							-- if (switchReqDelay >= 0) then
							-- 	if (count > 100) then
							-- 		printf("Not Logging!")
							-- 	else
							-- 		fp:write(("%d, %d, %d, %d, %d, %d \n"):format(count, switchReqDelay, switchDelay, respEgressDelay, lat - (switchDelay + respEgressDelay)))
							-- 	end
							-- end
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
