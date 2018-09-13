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


local SRC_IP = "10.0.0.1"
local DST_IP = "11.0.0.1"

local INTEL_ETHDST_1 = "3C:FD:FE:BD:01:A4"
local NFP_ETHSRC_1 = "46:B2:7A:20:26:34"
local TYPE_TS = 0x1235
local PKT_SIZE	= 34
local UDP_PKT_SIZE = 1000

constants = {
    defaultPayload    = "\x01\x02 hello"
}
function configure(parser)
	parser:description("Generates a Timesync Request, and displays the Timestamp obtained from Master Clock")
	parser:argument("txDev", "Device to transmit from."):convert(tonumber)
	parser:argument("rxDev", "Device to receive from."):convert(tonumber)

end

function master(args)
  txDev = device.config({port = args.txDev, rxQueues = 1, txQueues = 1})
	rxDev = device.config({port = args.rxDev, rxQueues = 1, txQueues = 1})
  device.waitForLinks()
	txQueue = txDev:getTxQueue(0)
	rxQueue = rxDev:getTxQueue(0)

	mg.startSharedTask("CrossTraffic", txDev:getTxQueue(0))

	--mg.startTask("doRecvCrossTraffic", rxDev:getTxQueue(0))
	stats.startStatsTask{txDev, rxDev}

  mg.waitForTasks()

end


function doRecvCrossTraffic(queue)
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethSrc = queue,
			ethDst = ETHLOOP_DST,
			ethType = 0x1234
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
		-- buf:getUdpPacket():fill{
		-- 	ethSrc = queue,
		-- 	ethDst = INTEL_ETHDST_1,
		-- 	ip4Src = SRC_IP,
		-- 	ip4Dst = DST_IP,
		-- 	udpSrc = "100",
		-- 	udpDst = "100",
		-- 	pktLength = UDP_PKT_SIZE
		-- }
		buf:getTcpPacket(ipv4):fill{
			ethSrc = queue,
			ethDst = INTEL_ETHDST_1,
			ip4Src = SRC_IP,
			ip4Dst = DST_IP,
			tcpSeqNumber = 1,
			tcpWindow = 10,
			pktLength = UDP_PKT_SIZE,
		}
	end)
	local bufs = mem:bufArray()
	bufs:alloc(UDP_PKT_SIZE)
	local payLength = 100
	for i, buf in ipairs(bufs) do
	  local pkt = buf:getTcpPacket()
		local j = 0
		while j < payLength do
				pkt.payload.uint8[j] =
						string.byte(constants.defaultPayload, j + 1) or 0
				j = j + 1
		end
	end


	while mg.running() do
		queue:send(bufs)
	end
end
