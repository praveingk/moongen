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
local ETHLOOP_DST   = "a0:00:00:00:00:0a"

local ETH_SRC	= "3c:fd:fe:b7:e7:f4"
local ETH_SRC1	= "3c:fd:fe:b7:e7:f5"
local BCAST     = "FF:FF:FF:FF:FF:FF"
local DUMMY_DST = "3c:fd:fe:b7:e7:f9"

local SWITCHMASTER = "a0:00:00:20:00:0a"

local PKT_SIZE	= 34
local UDP_PKT_SIZE = 1000

local avg_nic_delay_0 = 0
local avg_nic_delay_1 = 0
local LINE_RATE = 10000000000 -- 10 Gbps

function configure(parser)
	parser:description("Generates a DPTP Request, and displays the Timestamp obtained from Master Clock")
	parser:argument("tx1Dev", "Primary Device to transmit/receive from."):convert(tonumber)
	parser:argument("tx2Dev", "Device to transmit/receive from. This applies when you want to synchronize multiple NIC ports"):default(0):convert(tonumber)

	parser:option("-c", "Start CrossTraffic"):default(0):convert(tonumber)
	parser:option("-d", "Start receiving CrossTraffic"):default(0):convert(tonumber)

	parser:option("-f --file", "."):default("dptp.csv")
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
end

function master(args)
  tx1Dev = device.config({port = args.tx1Dev, rxQueues = 3, txQueues = 3})
  tx2Dev = device.config({port = args.tx2Dev, rxQueues = 2, txQueues = 2})

  device.waitForLinks()
  tx1Queue = tx1Dev:getTxQueue(1)
  rx1Queue = tx1Dev:getRxQueue(1)
  tx2Queue = tx2Dev:getTxQueue(1)
  rx2Queue = tx2Dev:getRxQueue(1)

  tx1Queue:enableTimestamps()
  rx1Queue:enableTimestamps()
  tx2Queue:enableTimestamps()
  rx2Queue:enableTimestamps()
  -- Below is a mandatory and important command to put Timesync packets to RX Queue 1.
  rx1Queue:filterL2Timestamps()
  rx2Queue:filterL2Timestamps()

	printf("CrossTraffic=%d", args.c)

	if args.c == 1 then
		mg.startSharedTask("CrossTraffic", tx1Dev:getTxQueue(0))
	end
	if args.d == 1 then
		printf("Starting to receive CrossTraffic")
		tx1Dev:getTxQueue(0):setRate(args.rate)
		mg.startSharedTask("doRecvCrossTraffic", tx1Dev:getTxQueue(0))
	end

  file = "dptp.csv"
  mg.startSharedTask("initiateDPTPHost", tx1Dev, tx1Queue, rx1Queue, tx2Dev, tx2Queue, rx2Queue, file)

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

function initiateDPTPHost(tx1Dev, tx1Queue, rx1Queue, tx2Dev, tx2Queue, rx2Queue, file)
	local i = 0
	mg.sleepMillis(1000)
	fp = io.open(file, "w")
	local mem1 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = tx1Queue,
			ethDst = SWITCHMASTER,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	local mem2 = memory.createMemPool(function(buf)
		buf:getTimesyncPacket():fill{
			ethSrc = tx2Queue,
			ethDst = SWITCHMASTER,
			ethType = proto.eth.TYPE_TS,
			command = proto.timesync.TYPE_REQ,
		}
	end)
	while mg.running() do
		i = i + 1
		syncClocks(tx1Dev, tx2Dev)
		printf(red("Dev 0 "))
		mg.sleepMillis(1)
		calc_time1_dptp, x1, y1 = startTimesync(i, mem1, tx1Dev, tx1Queue, rx1Queue, fp)
		mg.sleepMillis(1)
		printf(red("Dev 1 "))
		calc_time2_dptp, x2, y2 = startTimesync(i, mem2, tx2Dev, tx2Queue, rx2Queue, fp)

		if (x1 ~= nil and x2~=nil) then
			local diff_time = x2-x1
			local diff_ref_time = y2-y1
			local drift_now = (y2 - y1) - (x2 - x1)

			-- printf("Diff_ref_time = %d", diff_ref_time);
			-- printf("Diff_time = %d", diff_ref_time);
			-- printf("%d-%d(%d) %d-%d(%d)", y1, y2,y2-y1, x1, x2, x2-x1)
			-- printf("Drift now = %d", drift_now)
			-- printf("%u:%u", calc_time1_dptp + drift_now,  calc_time2_dptp)

			--if (calc_time1_dptp > 0 and calc_time2_dptp > 0) then
				printf("Error in clock between Dev0 & Dev1= %d",calc_time2_dptp - calc_time1_dptp - drift_now)
				fp:write(("%d,%d\n"):format(i, calc_time2_dptp - calc_time1_dptp - drift_now))
			--end
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
	local curr_rate
	
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
			rxBufs:freeAll()
		else
			for i=1,rx do
				local rxBuf = rxBufs[i]
				local rxPkt = rxBuf:getTimesyncPacket()
        --rxBuf:dump()
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
						-- lat_2probe = rxTs - txDelayTs
						-- clientDelay_2probe = txReqTs - txDelayTs
						reference_lo = rxPkt.timesync:getReference_ts_lo()
						curr_rate = rxPkt.timesync:getRate()
						elapsedTs = rxPkt.timesync:getIgTs()
						egTs = rxPkt.timesync:getEgTs()
						macTs = rxPkt.timesync:getMacTs()
						switchDelay = rxPkt.timesync:getEgTs() - rxPkt.timesync:getIgTs()
						switchReqDelay = rxPkt.timesync:getIgTs() - rxPkt.timesync:getMacTs();
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
							local nic_wire_delay = lat - (switchReqDelay + switchDelay + respEgressDelay)

							local rate_percent = (curr_rate*8)/LINE_RATE

							printf(green(rxPkt.timesync:getString()))
							printf(green("Device = %d", txDev.id))
							printf(green("Switch Request Delay = %d ns", switchReqDelay))
							printf(green("Switch Queing Delay = %d ns", switchDelay))
							printf(green("Switch Response Egress Delay =%d ns", respEgressDelay))
							printf("---------------------------------");
							printf(green("Latency = %d ns", lat))
							printf(green("Unaccounted delay = %d ns", nic_wire_delay))
							printf(green("Response delay = %d ns", replydelay_dptp))
							printf(green("Current Traffic Rate = %d bps", rate_percent))
							printf("---------------------------------")
							if (rate_percent < 0.0001) then
								if (txDev.id == 0) then
									if (avg_nic_delay_0 == 0) then
										avg_nic_delay_0 = nic_wire_delay
									else
										avg_nic_delay_0 = (avg_nic_delay_0 + nic_wire_delay)/2
									end
									printf(green("Avg NIC Delay = %d", avg_nic_delay_0))
									printf("---------------------------------")
								else
									if (avg_nic_delay_1 == 0) then
										avg_nic_delay_1 = nic_wire_delay
									else
										avg_nic_delay_1 = (avg_nic_delay_1 + nic_wire_delay)/2
									end
									printf(green("Avg NIC Delay = %d", avg_nic_delay_1))
									printf("---------------------------------")
								end
							end


							local calc_time_lo_dptp = reference_lo + (replydelay_dptp % max_ns);

							printf(green("calc_time_lo_dptp = %d ns", calc_time_lo_dptp))

							local calc_time_igref_dptp = calc_time_lo_dptp - rxTs
							rxBufs:freeAll()
							--fp:write(("%d, %d, %d\n"):format(count, txReqTs, calc_time_lo_dptp))
							return calc_time_igref_dptp, rxTs, capture_tx
					end
				end
			end
		end
	end
	return -1,-1,-1
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
