﻿/*
 * Collie - An asynchronous event-driven network framework using Dlang development
 *
 * Copyright (C) 2015-2016  Shanghai Putao Technology Co., Ltd 
 *
 * Developer: putao's Dlang team
 *
 * Licensed under the Apache-2.0 License.
 *
 */
module collie.bootstrap.clientmanger;

import collie.socket;
import collie.channel;
import collie.utils.timingwheel;
import collie.utils.memory;
import collie.utils.functional;


class ClientManger(PipeLine)
{
	alias ClientConnection = ClientLink!PipeLine;
	alias PipeLineFactory = PipelineFactory!PipeLine;

	this(EventLoop loop)
	{
		_loop = loop;
	}
	
	~this()
	{
		if (_timer)
			_timer.destroy;
	}

	void pipelineFactory(shared PipeLineFactory fac)
	{
		_factory = fac;
	}

	void connect(Address to, CallBack cback = null)
	{
		LinkInfo * info = new LinkInfo();
		info.addr = to;
		info.tryCount = 0;
		info.cback = cback;
		connect(info);
	}

	void close()
	{
		foreach(con,fd ; _list)
		{
			con.close();
		}
	}

	@property tryCount(){return _tryCount;}
	@property tryCount(uint count){_tryCount = count;}

	alias heartbeatTimeOut = startTimeOut;
	// 定时器不精确，需要小心误差
	bool startTimeOut(uint s)
	{
		return getTimeWheelConfig(s);
	}

	@property EventLoop eventLoop()
	{
		return _loop;
	}

protected:
	void connect(LinkInfo * info)
	{
		info.client = new TCPClient(_loop);
		info.client.setCloseCallBack(bind(&closeCallBack,info));
		info.client.setConnectCallBack(bind(&connectCallBack,info));
		info.client.setReadCallBack(bind(&readCallBack,info));
		info.client.connect(info.addr);
	}

	void connectCallBack(LinkInfo * info,bool isconnect)
	{
		if(info is null)
			return;
		if(isconnect)
		{
			auto pipe = _factory.newPipeline(info.client);
			if(!pipe)
			{
				gcFree(info.client);
				gcFree(info);
				return;
			}
			ClientConnection con = new ClientConnection(this,pipe);
			_wheel.addNewTimer(con);
			_list[con] = 0;
			con.initialize();
		}
		else
		{// 重试一次，失败就释放资源
			if(info.tryCount < _tryCount) {
				gcFree(info.client);
				info.tryCount ++;
				connect(info);
			}
			else 
			{
				auto cback = info.cback;
				gcFree(info.client);
				gcFree(info);
				cback();
			}
		}
	}

	void closeCallBack(LinkInfo * info)
	{
	}

	void readCallBack(LinkInfo * info,ubyte[] buffer)
	{
		info.client.close();
	}

	void remove(ClientConnection con)
	{
		_list.remove(con);
		gcFree(con);
	}

	bool getTimeWheelConfig(uint _timeOut)
	{
		uint whileSize;uint time; 
		if (_timeOut == 0)
			return false;
		if (_timeOut <= 40)
		{
			whileSize = 50;
			time = _timeOut * 1000 / 50;
		}
		else if (_timeOut <= 120)
		{
			whileSize = 60;
			time = _timeOut * 1000 / 60;
		}
		else if (_timeOut <= 600)
		{
			whileSize = 100;
			time = _timeOut * 1000 / 100;
		}
		else if (_timeOut < 1000)
		{
			whileSize = 150;
			time = _timeOut * 1000 / 150;
		}
		else
		{
			whileSize = 180;
			time = _timeOut * 1000 / 180;
		}
		if (_timer)
			return false;
		_timer = new Timer(_loop);
		_wheel = new TimingWheel(whileSize);
		_timer.setCallBack((){_wheel.prevWheel();});
		return _timer.start(time);
	}

private:
	int[ClientConnection] _list;

	shared PipeLineFactory _factory;
	TimingWheel _wheel;
	Timer _timer;
	EventLoop _loop;

	uint _tryCount;
}

package:

struct LinkInfo
{
	TCPClient client;
	Address addr;
	uint tryCount = 0;
	CallBack cback;
}


final @trusted class ClientLink(PipeLine) : WheelTimer, PipelineManager
{
	alias ConnectionManger = ClientManger!PipeLine;

	pragma(inline, true) void initialize()
	{
		_pipe.transportActive();
	}

	pragma(inline, true) void close()
	{
		_pipe.transportInactive();
	}

	override void onTimeOut() nothrow
	{
		try{
			_pipe.timeOut();
		}catch{}
	}

	override void refreshTimeout() 
	{
		rest();
	}

	override void deletePipeline(PipelineBase pipeline)
	{
		pipeline.pipelineManager = null;
		stop();
		_manger.remove(this);
	}
protected:
	this(ConnectionManger manger, PipeLine pipe)
	{
		_manger = manger;
		_pipe = pipe;
		_pipe.finalize();
		_pipe.pipelineManager(this);
	}

private:
	ConnectionManger _manger;
	PipeLine _pipe;
	string _name;
}
