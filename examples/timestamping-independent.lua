--- Hardware timestamping.
local mod = {}

local ffi    = require "ffi"
local dpdkc  = require "dpdkc"
local dpdk   = require "dpdk"
local device = require "device"
local eth    = require "proto.ethernet"
local memory = require "memory"
local timer  = require "timer"
local log    = require "log"
local filter = require "filter"
local libmoon = require "libmoon"
local mg     = require "moongen"
local timestamper = {}
timestamper.__index = timestamper

local ETH_DST = "3c:fd:fe:b7:e7:f5"
--- Create a new timestamper.
--- A NIC can only be used by one thread at a time due to clock synchronization.
--- Best current pratice is to use only one timestamping thread to avoid problems.

function configure(parser)
	parser:description("Generates bidirectional CBR traffic with hardware rate control and measure latencies.")
	parser:argument("dev1", "Device to transmit/receive from."):convert(tonumber)
	parser:argument("dev2", "Device to transmit/receive from."):convert(tonumber)
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
	parser:option("-f --file", "Filename of the latency histogram."):default("histogram.csv")
end


function master(args)
	local dev1 = device.config({port = args.dev1, rxQueues = 2, txQueues = 2})
	local dev2 = device.config({port = args.dev2, rxQueues = 2, txQueues = 2})
	device.waitForLinks()
	mg.startTask("newTimestamper", dev1:getTxQueue(1), dev2:getRxQueue(1))
	mg.waitForTasks()
end

function newTimestamper(txQueue, rxQueue, mem, udp, doNotConfigureUdpPort)
	mem = mem or memory.createMemPool(function(buf)
		-- defaults are good enough for us here
		udp = 1
		if udp then
			buf:getUdpPtpPacket():fill{
				ethSrc = txQueue,
				ethDst = rxQueue,
			}
		else
			printf("Sending Ptp Packets")
			buf:getPtpPacket():fill{
				ethSrc = txQueue,
			}
		end
	end)
	printf("Enabling timestamps")
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()
	if udp and rxQueue.dev.supportsFdir then
		rxQueue:filterUdpTimestamps()
	elseif not udp then
		rxQueue:filterL2Timestamps()
	end
	txBufs = mem:bufArray(1)
	rxBufs = mem:bufArray(128)
	txDev = txQueue.dev
	rxDev = rxQueue.dev
	while mg.running() do
		measureLatency(function(buf) buf:getEthernetPacket().eth.dst:setString(ETH_DST) end,txBufs, rxBufs, txQueue, rxQueue, txDev, rxDev)
		mg.sleepMillis(1000)
	end
end


--- Try to measure the latency of a single packet.
--- @param pktSize optional, the size of the generated packet, optional, defaults to the smallest possible size
--- @param packetModifier optional, a function that is called with the generated packet, e.g. to modified addresses
--- @param maxWait optional (cannot be the only argument) the time in ms to wait before the packet is assumed to be lost (default = 15)
function measureLatency(packetModifier, txBufs, rxBufs, txQueue, rxQueue, txDev, rxDev)
	udp = true
	seq = 1
	pktSize = pktSize or udp and 76 or 60
	maxWait = (maxWait or 15) / 1000
	txBufs:alloc(pktSize)
	local buf = txBufs[1]
	buf:enableTimestamps()
	local expectedSeq = seq
	seq = (seq + 1) % 2^16
	if udp then
		buf:getUdpPtpPacket().ptp:setSequenceID(expectedSeq)
	else
		buf:getPtpPacket().ptp:setSequenceID(expectedSeq)
	end
	local skipReconfigure
	if packetModifier then
		skipReconfigure = packetModifier(buf)
	end
	if udp then
			-- change timestamped UDP port as each packet may be on a different port
		--printf("Enabling timestamp for udp port %d\n", buf:getUdpPacket().udp:getDstPort())
		rxQueue:enableTimestamps(buf:getUdpPacket().udp:getDstPort())
		buf:getUdpPtpPacket():setLength(pktSize)
		--buf:getUdpPtpPacket().eth:setDstString(ETH_DST)
		--buf:getUdpPtpPacket():dump()
		txBufs:offloadUdpChecksums()
		if rxQueue.dev.reconfigureUdpTimestampFilter and not skipReconfigure then
			-- i40e driver fdir filters are broken
			-- it is not possible to match on flex bytes in udp packets without matching IPs and ports as well
			-- so we have to look at that packet and reconfigure the filters
			--printf("Reconfigure udp timestamp filter")
			rxQueue.dev:reconfigureUdpTimestampFilter(rxQueue, buf:getUdpPacket())
		end
	end
	syncClocks(txDev, rxDev)
	-- clear any "leftover" timestamps
	rxDev:clearTimestamps()
	txQueue:send(txBufs)
	local tx = txQueue:getTimestamp(500)
	local numPkts = 0
	if tx then
		-- sent was successful, try to get the packet back (assume that it is lost after a given delay)
		printf("Packet Sent")
		local timer = timer:new(maxWait)
		while timer:running() do
			local rx = rxQueue:tryRecv(rxBufs, 1000)
			numPkts = numPkts + rx
			printf("num Packets = %d", numPkts)
			local timestampedPkt = rxDev:hasRxTimestamp()
			if not timestampedPkt then
				-- NIC didn't save a timestamp yet, just throw away the packets
				printf("Response is not timestamped")
				rxBufs:freeAll()
			else
				-- received a timestamped packet (not necessarily in this batch)
				printf("Response has timestamp")
				for i = 1, rx do
					local buf = rxBufs[i]
					local timesync = rxQueue.dev.useTimsyncIds and buf:getTimesync() or 0
					local seq = (udp and buf:getUdpPtpPacket() or buf:getPtpPacket()).ptp:getSequenceID()
					if buf:hasTimestamp() and seq == expectedSeq and (seq == timestampedPkt or timestampedPkt == -1) then
						-- yay!
						local rxTs = rxQueue:getTimestamp(nil, timesync)
						if not rxTs then
							-- can happen if you hotplug cables
							return nil, numPkts
						end
						rxBufs:freeAll()

						local lat = rxTs - tx
						if lat > 0 and lat < 2 * maxWait * 10^9 then
							-- negative latencies may happen if the link state changes
							-- (timers depend on a clock that scales with link speed on some NICs)
							-- really large latencies (we only wait for up to maxWait ms)
							-- also sometimes happen since changing to DPDK for reading the timing registers
							-- probably something wrong with the DPDK wraparound tracking
							-- (but that's really rare and the resulting latency > a few days, so we don't really care)
							printf("Latency = %d ns", lat)
							return lat, numPkts
						end
					elseif buf:hasTimestamp() and (seq == timestampedPkt or timestampedPkt == -1) then
						-- we got a timestamp but the wrong sequence number. meh.
						rxQueue:getTimestamp(nil, timesync) -- clears the register
						-- continue, we may still get our packet :)
					elseif seq == expectedSeq and (seq ~= timestampedPkt and timestampedPkt ~= -1) then
						-- we got our packet back but it wasn't timestamped
						-- we likely ran into the previous case earlier and cleared the ts register too late
						rxBufs:freeAll()
						return nil, numPkts
					end
				end
			end
		end
		-- looks like our packet got lost :(
		return nil, numPkts
	else
		-- happens when hotplugging cables
		log:warn("Failed to timestamp packet on transmission")
		timer:new(maxWait):wait()
		return nil, numPkts
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
