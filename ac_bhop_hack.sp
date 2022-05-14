#pragma semicolon 1

//-------------------------------------------------------------------------
// Plugin info
//-------------------------------------------------------------------------
#define PLUGIN_VERSION "1.01"
public Plugin:myinfo = 
{
    name = "Bhop hack anti-cheat",
    author = "Aoki",
    description = "Detect certain bhop hacks",
    version = PLUGIN_VERSION,
    url = ""
}

//-------------------------------------------------------------------------
// Includes
//-------------------------------------------------------------------------
#include <sourcemod>
#include <sdktools>

//-------------------------------------------------------------------------
// Defines 
//-------------------------------------------------------------------------
#define LOG_ALL_CHEAT_JUMPS 1
#define OFFENSES_TO_LOG_ALL_CHEAT_JUMPS 1
#define DO_BANS 1
#define RESTICT_USAGE 1
#define ANNOUNCE_BANS 1

#define LOG_DEBUG_ENABLE 0
#define LOG_TO_CHAT 1
#define LOG_TO_SERVER 1
#define LOG_TO_FILE 0

#define MAX_LEN_PLAYER_NAME 92
#define MAX_LEN_PLAYER_AUTH 23
#define MAX_LEN_MAP_NAME 128
#define MAX_STRING_LEN 256

#define TICK_RATE 100
#define TICK_RATE_MULT (TICK_RATE / 100)
#define MAX_TICKS_IN_BHOP_JUMP (2 * 68 * TICK_RATE_MULT) //time for 2 bhops
#define NUM_JUMPS_TO_CLASSIFY_AS_BHOPPING 3
#define CHEAT_JUMP_TIME_GATE_TICKS (100 * TICK_RATE_MULT * 6)

#define HALF_JUMP_TIME_TICKS (70 / 2)
#define MIN_SPEED_FOR_BHOP_CHEAT_CHECK 375
#define MIN_TICKS_BETWEEN_CHEAT_JUMPS 20

#define JUMP_AVG_WINDOW (10.0)
#define MAX_JUMP_PRESSES 10
#define NUM_JUMP_PRESS_FOR_ANALYSIS 2
#define PERFECT_JUMP_BAN_THRESHOLD (0.94)
#define MIN_PERF_JUMPS_FOR_CHEAT (0.2)
#define CHEAT_JUMP_COUNT_BAN_THRESH 5
#define JUMP_TICK_DELTA_STD_DEV 0.55

//-------------------------------------------------------------------------
// Types 
//-------------------------------------------------------------------------
enum teCheatType (+= 1)
{
	eeCheatNone = 0,
	eeCheatOneJumps,
	eeCheatMasking1,
	eePerfJumpThresh
};

//-------------------------------------------------------------------------
// Globals 
//-------------------------------------------------------------------------
new gnTick = 0;
new String:gpanLogFile[MAX_STRING_LEN];
new Handle:ghUseSourceBans;

#if LOG_ALL_CHEAT_JUMPS == 1
new String:gpanAllLogFile[MAX_STRING_LEN];
#endif

new String:gpanCurrentMap[MAX_LEN_MAP_NAME];

//Player data
new String:gpanPlayerName[MAXPLAYERS+1][MAX_LEN_PLAYER_NAME];
new String:gpanPlayerAuth[MAXPLAYERS+1][MAX_LEN_PLAYER_AUTH];
new ganPrevJumpTick[MAXPLAYERS+1] = { 0, ... };
new ganThisJumpTick[MAXPLAYERS+1] = { -1, ... };
new bool:gaePressingJump[MAXPLAYERS+1] = { false, ... };
new bool:gaeIsBhopping[MAXPLAYERS+1] = { false, ... };
new ganBhopCount[MAXPLAYERS+1] = { 0, ... };
new ganThisJumpPressTick[MAXPLAYERS+1] = { 0, ... };
new ganPrevJumpPressTick[MAXPLAYERS+1] = { 0, ... };
new ganPrevTicksOnGround[MAXPLAYERS+1] = { 0, ... };
new ganTicksOnGround[MAXPLAYERS+1] = { 0, ... };
new Float:garAvgPerfJump[MAXPLAYERS+1] = { 0.333, ... };
new Float:garAvgOnGround[MAXPLAYERS+1] = { 1.0, ... };
new gaanJumpPressTickDeltas[MAXPLAYERS+1][MAX_JUMP_PRESSES];
new ganTickDeltaIdx[MAXPLAYERS+1] = { 0, ... };

//number of ticks since last jump press, saved on jump event: EvJumpNumTicksSinceLastJumpPress
new ganTicksSinceLastJump[MAXPLAYERS+1] = { 0, ... }; 

new ganCheatJumpCount[MAXPLAYERS+1] = { 0, ... };
new ganMaxCheatJumpCount[MAXPLAYERS+1] = { 0, ... };
new ganLastCheatJumpTick[MAXPLAYERS+1] = { 0, ... };
new Float:garJumpTickDeltaAvg[MAXPLAYERS+1] = { 0.0 , ... };
new Float:garJumpTickDeltaStd[MAXPLAYERS+1] = { 0.0 , ... };
new Float:garAvgJumpNum[MAXPLAYERS+1] = { 3.0 , ... };
	
//-------------------------------------------------------------------------
// Startup functions
//-------------------------------------------------------------------------
public OnPluginStart()
{   
	BuildPath(Path_SM, gpanLogFile, MAX_STRING_LEN, "logs/ac_bh_hack.log");
	
	#if LOG_ALL_CHEAT_JUMPS == 1
	BuildPath(Path_SM, gpanAllLogFile, MAX_STRING_LEN, "logs/ac_bh_hack_all.log");
	LogToFile(gpanAllLogFile,"Bhop hack AC ver %s loaded.",PLUGIN_VERSION);
	#endif
	
	ghUseSourceBans = CreateConVar("sm_ac_sourcebans","0","Anti-cheat will write to SourceBans",FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	
	CreateConVar("bh_hack_ac_version", PLUGIN_VERSION, "Bhop hack AC version", FCVAR_PLUGIN|FCVAR_NOTIFY|FCVAR_REPLICATED);
	HookEvent("player_jump", evPlayerJump, EventHookMode_Post);
	RegAdminCmd("ac_stats", cbPrintJumpStats, ADMFLAG_SLAY, "ac_stats");
	
	LogToFile(gpanLogFile,"Bhop hack AC ver %s loaded.",PLUGIN_VERSION);
	
	GetCurrentMap(gpanCurrentMap,sizeof(gpanCurrentMap));
	GetPlayerNamesAndAuths();
}

public OnClientAuthorized(anClient, const String:apanAuth[])
{
	GetClientName(anClient,gpanPlayerName[anClient],MAX_LEN_PLAYER_NAME);
	GetClientAuthString(anClient,gpanPlayerAuth[anClient],MAX_LEN_PLAYER_AUTH);

	gaeIsBhopping[anClient] = false;
	ganBhopCount[anClient] = 0;
	garAvgPerfJump[anClient] = 0.333;
	garAvgOnGround[anClient] = 1.0;
	ganTickDeltaIdx[anClient] = 0;
	ganCheatJumpCount[anClient] = 0;
	ganMaxCheatJumpCount[anClient] = 0;
	garAvgJumpNum[anClient] = 0.0;
}

public OnMapStart()
{
	GetCurrentMap(gpanCurrentMap,sizeof(gpanCurrentMap));
}

//-------------------------------------------------------------------------
// Main processing
//-------------------------------------------------------------------------
GetPlayerNamesAndAuths()
{
	for(new i=1;i<=MaxClients;i++)
	{
		if(IsClientConnected(i) && IsClientAuthorized(i))
		{
			GetClientName(i,gpanPlayerName[i],MAX_LEN_PLAYER_NAME);
			GetClientAuthString(i,gpanPlayerAuth[i],MAX_LEN_PLAYER_AUTH);
		}
	}
}

Float:GetPlayerXyVelocity(anClient)
{
	decl Float:paarPlayerVelocity[3];
	GetEntPropVector(anClient, Prop_Data, "m_vecVelocity", paarPlayerVelocity);
	paarPlayerVelocity[2] = 0.0;
	return GetVectorLength(paarPlayerVelocity);
}

bool:IsPlayerBhopping(anClient)
{
	new bool:leReturn = false;
	new Float:lrXyVelocity = GetPlayerXyVelocity(anClient);
	
	if(ganThisJumpTick[anClient] - ganPrevJumpTick[anClient] < MAX_TICKS_IN_BHOP_JUMP &&
	   lrXyVelocity > MIN_SPEED_FOR_BHOP_CHEAT_CHECK)
	{
		if(ganBhopCount[anClient] > NUM_JUMPS_TO_CLASSIFY_AS_BHOPPING)
		{
			leReturn = true;
		}	
		
		ganBhopCount[anClient]++;
	}
	else if(gaeIsBhopping[anClient] == true && leReturn == false)
	{
		ganBhopCount[anClient] = 0;
	}
	
	return leReturn;
}

teCheatType:IsJumpCheated(anClient)
{
	new teCheatType:leReturn = eeCheatNone;
	
	if(garAvgPerfJump[anClient] > MIN_PERF_JUMPS_FOR_CHEAT)
	{
		//If only one jump press per jump
		if(ganTickDeltaIdx[anClient] == 0 &&
		   ganTicksSinceLastJump[anClient] > HALF_JUMP_TIME_TICKS)
		{
			leReturn = eeCheatOneJumps;
		}
		//Else if more jumps presses
		else if(ganTickDeltaIdx[anClient] >= NUM_JUMP_PRESS_FOR_ANALYSIS)
		{
			garJumpTickDeltaAvg[anClient] = 
				CalcMean(gaanJumpPressTickDeltas[anClient],ganTickDeltaIdx[anClient],true);
			
			garJumpTickDeltaStd[anClient] =
				CalcStdDev(gaanJumpPressTickDeltas[anClient],ganTickDeltaIdx[anClient],true);
			
			if(garJumpTickDeltaStd[anClient] < JUMP_TICK_DELTA_STD_DEV &&
			   ganTicksSinceLastJump[anClient] > HALF_JUMP_TIME_TICKS)
			{
				leReturn = eeCheatMasking1;
			}
		}
	}
	
	//For stats only
	garAvgJumpNum[anClient] = ( garAvgJumpNum[anClient] * (JUMP_AVG_WINDOW-1.0) + 
		float(ganTickDeltaIdx[anClient]) ) / JUMP_AVG_WINDOW;
	
	ganTickDeltaIdx[anClient] = 0; 
	
	return leReturn;
}

ProcessJumpPresses(anClient,anButtons)
{
	if(anButtons & IN_JUMP)
	{
		gaePressingJump[anClient] = true;
		
		if(gnTick <= ganThisJumpTick[anClient] + HALF_JUMP_TIME_TICKS &&
		   gaeIsBhopping[anClient] == true &&
		   ganTickDeltaIdx[anClient] < MAX_JUMP_PRESSES)
		{
			//save data when jumps are pressed
			gaanJumpPressTickDeltas[anClient][ganTickDeltaIdx[anClient]] = 
				gnTick - ganThisJumpPressTick[anClient];
			
			ganTickDeltaIdx[anClient]++;
		}
		
		ganPrevJumpPressTick[anClient] = ganThisJumpPressTick[anClient];
		ganThisJumpPressTick[anClient] = gnTick;
	}
	else
	{
		gaePressingJump[anClient] = false;
	}
}

ProcessOnGroundFlag(anClient)
{
	ganPrevTicksOnGround[anClient] = ganTicksOnGround[anClient];

	if(GetEntityFlags(anClient) & FL_ONGROUND)
	{
		ganTicksOnGround[anClient]++;
	}
	else
	{
		ganTicksOnGround[anClient] = 0;
	}
}

ProcessPerfJumps(anClient)
{
	garAvgOnGround[anClient] = ( garAvgOnGround[anClient] * (JUMP_AVG_WINDOW-1.0) + 
		float(ganPrevTicksOnGround[anClient]) ) / JUMP_AVG_WINDOW;
	
	if(ganPrevTicksOnGround[anClient] == 0)
	{
		garAvgPerfJump[anClient] = 
			(garAvgPerfJump[anClient] * (JUMP_AVG_WINDOW-1.0) + 1.0) / JUMP_AVG_WINDOW;
	}
	else
	{
		garAvgPerfJump[anClient] = 
			(garAvgPerfJump[anClient] * (JUMP_AVG_WINDOW-1.0)) / JUMP_AVG_WINDOW;
	}
	
	if(garAvgPerfJump[anClient] > PERFECT_JUMP_BAN_THRESHOLD)
	{
		HandleCheater(anClient,eePerfJumpThresh);
	}
	
	//LogDebug("prev=%d, AvgG=%1.4f, AvgP=%1.4f, Vel = %3.1f",
	//	ganPrevTicksOnGround[anClient],
	//	garAvgOnGround[anClient],
	//	garAvgPerfJump[anClient],
	//	GetPlayerXyVelocity(anClient));
}

ProcessCheatJumpHistory(anClient)
{
	if(gnTick - ganLastCheatJumpTick[anClient] < CHEAT_JUMP_TIME_GATE_TICKS)
	{
		ganCheatJumpCount[anClient]++;
		
		if(ganCheatJumpCount[anClient] > ganMaxCheatJumpCount[anClient])
		{
			ganMaxCheatJumpCount[anClient] = ganCheatJumpCount[anClient];
		}
	}
	else
	{
		ganCheatJumpCount[anClient] = 0;
	}
	
	if(ganCheatJumpCount[anClient] > CHEAT_JUMP_COUNT_BAN_THRESH)
	{
		HandleCheater(anClient,eeCheatMasking1);
	}
	
	//LogDebug("cheat jump count=%d, tick dif=%d",ganCheatJumpCount[anClient],gnTick - ganLastCheatJumpTick[anClient]);
	
	ganLastCheatJumpTick[anClient] = gnTick;
}

//-------------------------------------------------------------------------
// Math
//-------------------------------------------------------------------------
Float:CalcMean(aanValues[],anNumValues,bool:aeExcludeFirstSample = false)
{
	new Float:lrSum = 0.0;
	new lnStartIdx = 0;
	new lnProcessedSamples = anNumValues;
	
	if(aeExcludeFirstSample == true && anNumValues > 2)
	{
		lnStartIdx = 1;
		lnProcessedSamples = anNumValues - 1;
	}

	for(new i=lnStartIdx;i<anNumValues;i++)
	{
		lrSum += float(aanValues[i]);
	}
	
	return lrSum / float(lnProcessedSamples);
}

Float:FloatSquare(Float:arVal)
{
	return arVal * arVal;
}

Float:CalcStdDev(aanValues[],anNumValues,bool:aeExcludeFirstSample = false)
{
	new Float:lrDeviationSqSum = 0.0;
	new Float:lrMean = CalcMean(aanValues,anNumValues,aeExcludeFirstSample);
	new lnStartIdx = 0;
	new lnProcessedSamples = anNumValues;
	
	if(aeExcludeFirstSample == true && anNumValues > 2)
	{
		lnStartIdx = 1;
		lnProcessedSamples = anNumValues - 1;
	}
	
	for(new i=lnStartIdx;i<anNumValues;i++)
	{
		lrDeviationSqSum += FloatSquare(float(aanValues[i]) - lrMean);
	}
	
	return SquareRoot(lrDeviationSqSum / float(lnProcessedSamples - 1));
}

//-------------------------------------------------------------------------
// Actions
//-------------------------------------------------------------------------
public Action:OnPlayerRunCmd(anClient, &apButtons, &apImpulse, Float:arVel[3], Float:arAngles[3], &apWeapon)
{
	if(IsPlayerAlive(anClient) && !IsFakeClient(anClient))
	{
		ProcessJumpPresses(anClient,apButtons);
		
		//OnGround values should be one tick behind
		ProcessOnGroundFlag(anClient);
		
		if(gnTick == ganThisJumpTick[anClient] + HALF_JUMP_TIME_TICKS &&
		   gaeIsBhopping[anClient] == true)
		{
			new teCheatType:leCheatType = IsJumpCheated(anClient);
		
			if(leCheatType != eeCheatNone && 
			   gnTick - ganLastCheatJumpTick[anClient] > MIN_TICKS_BETWEEN_CHEAT_JUMPS)
			{
				#if LOG_ALL_CHEAT_JUMPS == 1
				if(ganCheatJumpCount[anClient] > OFFENSES_TO_LOG_ALL_CHEAT_JUMPS)
				{
					LogCheaterData(gpanAllLogFile,anClient,leCheatType);
				}
				#endif
				
				ProcessCheatJumpHistory(anClient);
			}
		}
		
		if (apButtons & IN_LEFT || apButtons & IN_RIGHT)
        {
			HandleTurnFags(anClient);
        }
	}
	
	return Plugin_Continue;
}

HandleTurnFags(anClient)
{
	decl panSlayCount[MAXPLAYERS+1] = { 0, ... };
	
	ForcePlayerSuicide(anClient);
	PrintToChat(anClient,"\x04[Anti-cheat] \x03+left and +right are not allowed.");
	
	LogToFile(gpanLogFile,"Slayed %s (%s) for +left/+right",gpanPlayerName[anClient],gpanPlayerAuth[anClient]);
	
	panSlayCount[anClient]++;
	
	if(panSlayCount[anClient] >= 5)
	{
		KickClient(anClient,"Stop spamming +left/+right.");
		panSlayCount[anClient] = 0;
	}
}

public evPlayerJump(Handle:ahEvent, const String:apanName[], bool:aeDontBroadcast)
{
	new lnClient = GetClientOfUserId(GetEventInt(ahEvent, "userid"));
	
	if(!IsFakeClient(lnClient))
	{
		ganPrevJumpTick[lnClient] = ganThisJumpTick[lnClient];
		ganThisJumpTick[lnClient] = gnTick;

		gaeIsBhopping[lnClient] = IsPlayerBhopping(lnClient);
		
		if(gaeIsBhopping[lnClient] == true)
		{
			ProcessPerfJumps(lnClient);
		}
		else
		{
			garAvgPerfJump[lnClient] = 0.333;
			garAvgOnGround[lnClient] = 1.0;
			ganTickDeltaIdx[lnClient] = 0;
		}
		
		ganTicksSinceLastJump[lnClient] = gnTick - ganPrevJumpPressTick[lnClient];
	}
}

//-------------------------------------------------------------------------
// Game functions
//-------------------------------------------------------------------------
public OnGameFrame()
{
	gnTick++;
	
	if(gnTick < 0)
	{
		gnTick = 0;
	}
}

//-------------------------------------------------------------------------
// Data printout functions
//-------------------------------------------------------------------------
public Action:cbPrintJumpStats(anClient, ahArgs)
{
	for(new i=1;i<=MaxClients;i++)
	{
		if(IsClientConnected(i) && IsClientAuthorized(i) &&
		   IsPlayerAlive(i) && GetClientTeam(i) > 1)
		{
			if(gaeIsBhopping[i] == true)
			{
				PrintToConsole(anClient,
					"%s (%s) bhops=%d, off=%d/%d, perf=%1.4f, ground=%1.4f, tick(a%1.4f|s%1.4f), scroll=%1.1f, vel=%3.1f (%s)",
					gpanPlayerName[i],gpanPlayerAuth[i],ganBhopCount[i],
					ganCheatJumpCount[i],ganMaxCheatJumpCount[i],garAvgPerfJump[i],
					garAvgOnGround[i],garJumpTickDeltaAvg[i],garJumpTickDeltaStd[i],
					garAvgJumpNum[i],GetPlayerXyVelocity(i),gpanCurrentMap);
			}
			else
			{
				PrintToConsole(anClient,
					"%s (%s) not bhopping, off=%d",
					gpanPlayerName[i],gpanPlayerAuth[i],ganMaxCheatJumpCount[i]);
			}
		}
	}
    
	return Plugin_Handled;
}

LogCheaterData(String:apanFile[],anClient,teCheatType:aeCheatType)
{
	decl Float:panOrigin[3];
	GetEntPropVector(anClient, Prop_Send, "m_vecOrigin", panOrigin);

	LogToFile(apanFile,
		"%s (%s) type=%d, bhops=%d, off=%d/%d, perf=%1.4f, ground=%1.4f, tick(a%1.4f|s%1.4f), scroll=%1.1f, vel=%3.1f, %s(%3.1f,%3.1f,%3.1f), tick=%d",
		gpanPlayerName[anClient],gpanPlayerAuth[anClient],aeCheatType,ganBhopCount[anClient],
		ganCheatJumpCount[anClient],ganMaxCheatJumpCount[anClient],garAvgPerfJump[anClient],
		garAvgOnGround[anClient],garJumpTickDeltaAvg[anClient],garJumpTickDeltaStd[anClient],
		garAvgJumpNum[anClient],GetPlayerXyVelocity(anClient),gpanCurrentMap,
		panOrigin[0],panOrigin[1],panOrigin[2],gnTick);
}

KickClientIfValid(anClient)
{
	if(IsClientAuthorized(anClient) && IsClientInGame(anClient))
	{
		KickClient(anClient);
	}
}

HandleCheater(anClient,teCheatType:aeCheatType)
{
	LogCheaterData(gpanLogFile,anClient,aeCheatType);
		
	#if DO_BANS == 1
	if(GetConVarInt(ghUseSourceBans) == 1)
	{
		ServerCommand("sm_ban #%d 0 %s",GetClientUserId(anClient),"Bhop hack");
		
		KickClientIfValid(anClient);
	}
	else
	{
		BanClient(anClient,  
			0,  
			BANFLAG_AUTHID|BANFLAG_IP,  
			"Bhop cheating",  
			"Banned for bhop cheat");
	}
	#endif
	
	#if ANNOUNCE_BANS == 1
	PrintToChatAll("\x04[Anti-cheat] \x03%s (%s) banned for bhop hack.",gpanPlayerName[anClient],gpanPlayerAuth[anClient]);
	#endif
	
	ganCheatJumpCount[anClient] = 0;
	ganMaxCheatJumpCount[anClient] = 0;
}

//-------------------------------------------------------------------------
// Debug functions
//-------------------------------------------------------------------------
public LogDebug(const String:aapanFormat[], any:...)
{
#if LOG_DEBUG_ENABLE == 1
	decl String:ppanBuffer[512];
	
	VFormat(ppanBuffer, sizeof(ppanBuffer), aapanFormat, 2);
#if LOG_TO_CHAT == 1
	PrintToChatAll("%s", ppanBuffer);
#endif
#if LOG_TO_SERVER == 1
	PrintToServer("%s", ppanBuffer);
#endif
#if LOG_TO_FILE == 1
	LogToFile(gpanLogFile,"%s", ppanBuffer);
#endif
#endif
}















