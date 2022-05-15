#pragma semicolon 1

//-------------------------------------------------------------------------
// Plugin info
//-------------------------------------------------------------------------
#define PLUGIN_VERSION "0.94"
public Plugin:myinfo = 
{
    name = "Strafe anti-cheat",
    author = "Aoki",
    description = "Detect strafe hacks",
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
#define DO_BANS 1

#define LOG_DEBUG_ENABLE 0
#define LOG_TO_CHAT 1
#define LOG_TO_SERVER 1
#define LOG_TO_FILE 0

#define TICKRATE 100
#define TICKRATE_MULT (TICKRATE / 100)
#define LONG_JUMP_LENGTH_TICKS (78 * TICKRATE_MULT)

#define MAX_LEN_MAP_NAME 128

//Set to 64 if tracking bhop jumps
#define BHOP_JUMP_LENGTH_TICKS (76 * TICKRATE_MULT)
#define MAX_STRAFES (13) //Above this limit constitutes cheating
#define MAX_TICKS_PER_STRAFE (78)
#define LJ_DIST_PROC_THRESHOLD (240.0)
#define HYPER_STRAFE_DETS_FOR_BAN (3)
#define HYPER_STRAFE_BAN_TIME_IN_MINUTES (60 * 24)

#define EYE_YAW_IDX (1)
#define EYE_YAW_DELTA_STAFE_MIN (1.9)

//Detection defines
#define MIN_CHEAT_STRAFE_THRESH 5
#define MIN_CHEAT_STRAFE_MOVE_THRESH (0.985)
#define MAX_CHEAT_TICKS_PER_STRAFE (15.0)
#define MAX_CHEAT_TICKS_STD_DEV (1.0)
#define FLOAT_SUB_ZERO_THRESH (0.01)

#define MAX_FISHY_TICKS_STD_DEV (0.55)
#define MAX_FISHY_EYE_STD_DEV (0.45)
#define MAX_FISHY_PRO_EYE_MEAN (0.92)
#define MAX_FISHY_LOW_EYE_MEAN (0.81)
#define MAX_FISHY_PERF_EYE_MEAN (1.0)

//Indexing defines since SM won't let me use enum as index into float array
#define I_AVG 0
#define I_STD 1
#define I_DATA_TYPE_MAX 2
#define I_TICK 0
#define I_EYE  1
#define I_MOVE 2
#define I_EYED 3 //Eye Yaw Good Move Pct
#define I_BOTH 4
#define I_NONE 5
#define I_DATA_FIELD_MAX 6

#define MAX_LEN_PLAYER_NAME 92
#define MAX_LEN_PLAYER_AUTH 23
#define MAX_STRING_LEN 256

#define JUMP_NOT_FISHY 0
#define FISHY_PERF_JUMP (1<<1)
#define FISHY_TICKS_STD (1<<2)
#define FISHY_EYE_STD (1<<3)
#define FISHY_PERF_EYE (1<<4)
#define FISHY_PRO_EYE (1<<5)
#define FISHY_LOW_EYE (1<<6)

#define MAX_FISHY_JUMPS_IN_INTERVAL_FOR_CHEAT 3
#define MAX_FISHY_LOW_JUMPS_IN_INTERVAL_FOR_CHEAT 3
#define FISHY_INTERVAL_RESET_PRO_TICKS (8 * 100) //8 seconds
#define FISHY_INTERVAL_RESET_LOW_TICKS (8 * 100) //8 seconds

//-------------------------------------------------------------------------
// Types 
//-------------------------------------------------------------------------
enum teButtonType (+= 1)
{
	eeButtonJump = 0,
	eeButtonDuck,
	eeButtonL,
	eeButtonR,
	eeButtonMax
};

enum teStrafeDir (+= 1)
{
	eeStrafeNone = 0,
	eeStrafeLeft,
	eeStrafeRight,
	eeStrafeBoth
};

enum teCheatRule (+= 1)
{
	eeCheatPattern1 = 0,
	eeCheatPattern2,
	eeCheatPattern3,
	eeCheatPattern4,
	eeCheatPattern5,
	eeCheatPatternMax
};

//-------------------------------------------------------------------------
// Globals 
//-------------------------------------------------------------------------
new gnTick = 0;
new String:gpanLogFile[MAX_STRING_LEN];
new String:gpanFishyLogFile[MAX_STRING_LEN];
new Handle:ghUseSourceBans;

new String:gpanCurrentMap[MAX_LEN_MAP_NAME];

//Player data
new bool:gaaeButtonHolds[MAXPLAYERS+1][eeButtonMax];
new bool:gaePlayerInJump[MAXPLAYERS+1] = { false, ... };
new ganPlayerStartJumpTick[MAXPLAYERS+1] = { 0, ... };
new ganPlayerJumpHangtimeTicks[MAXPLAYERS+1] = { 0, ... };
new ganPlayerHyperStrafeStrikes[MAXPLAYERS+1] = { 0, ... };
new String:gpanPlayerName[MAXPLAYERS+1][MAX_LEN_PLAYER_NAME];
new String:gpanPlayerAuth[MAXPLAYERS+1][MAX_LEN_PLAYER_AUTH];

//Per tick player data
new bool:gaePlayerOnGround[MAXPLAYERS+1] = { false, ... };
new teStrafeDir:gaePlayerStrafeDir[MAXPLAYERS+1] = { eeStrafeNone, ... };
new teStrafeDir:gaePlayerEyeDir[MAXPLAYERS+1] = { eeStrafeNone, ... };
new Float:garPlayerNormalizedEyeYaw[MAXPLAYERS+1] = { 0.0, ... };

//Per jump data
new ganStrafeCount[MAXPLAYERS+1];
new teStrafeDir:gaeThisStrafeDir[MAXPLAYERS+1];
new teStrafeDir:gaePrevStrafeDir[MAXPLAYERS+1];
new Float:garPlayerStartJumpEyeYaw[MAXPLAYERS+1];
new Float:gaarPlayerStartJumpPos[MAXPLAYERS+1][3];
new Float:garData[MAXPLAYERS+1][I_DATA_TYPE_MAX][I_DATA_FIELD_MAX];
new Float:garJumpDistance[MAXPLAYERS+1];

//Single strafe data
new Float:gaarStrafeHoldingBothSum[MAXPLAYERS+1];
new Float:gaarStrafeHoldingNoneSum[MAXPLAYERS+1];
new Float:gaarStrafeGoodMoveDirTickSum[MAXPLAYERS+1];
new Float:gaarStrafeGoodEyeDirTickSum[MAXPLAYERS+1];
new Float:gaarStrafesEyeYaws[MAXPLAYERS+1][MAX_TICKS_PER_STRAFE];

//Per strafe data
new Float:gaarTicksPerStrafe[MAXPLAYERS+1][MAX_STRAFES];
new Float:gaarStrafeGoodMovePct[MAXPLAYERS+1][MAX_STRAFES];
new Float:gaarStrafeGoodEyeMovePct[MAXPLAYERS+1][MAX_STRAFES];
new Float:gaarStrafeHoldBothPct[MAXPLAYERS+1][MAX_STRAFES];
new Float:gaarStrafeHoldNonePct[MAXPLAYERS+1][MAX_STRAFES];
new Float:gaarStrafeEyeYawDeltaStdDev[MAXPLAYERS+1][MAX_STRAFES];

//Fishy tracking
new ganFishyCount[MAXPLAYERS+1] = { 0, ... };
new ganLastFishyTick[MAXPLAYERS+1] = { 0, ... };

new ganFishyLowCount[MAXPLAYERS+1] = { 0, ... };
new ganLastFishyLowTick[MAXPLAYERS+1] = { 0, ... };

new ganFishyCountMax[MAXPLAYERS+1] = { 0, ... };
new ganFishyLowCountMax[MAXPLAYERS+1] = { 0, ... };

//-------------------------------------------------------------------------
// Startup functions
//-------------------------------------------------------------------------
public OnPluginStart()
{   
	BuildPath(Path_SM, gpanLogFile, MAX_STRING_LEN, "logs/ac_strafe_cheats.log");
	BuildPath(Path_SM, gpanFishyLogFile, MAX_STRING_LEN, "logs/ac_strafe_fishy.log");
	
	ghUseSourceBans = CreateConVar("sm_ac_sourcebans","0","Anti-cheat will write to SourceBans",FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	
	CreateConVar("strafe_ac_version", PLUGIN_VERSION, "Strafe AC version", FCVAR_PLUGIN|FCVAR_NOTIFY|FCVAR_REPLICATED);
	HookEvent("player_jump", evPlayerJump, EventHookMode_Post);
	RegAdminCmd("sc_stats", cbPrintJumpStats, ADMFLAG_SLAY, "sc_stats");
	
	LogToFile(gpanLogFile,"Strafe AC ver %s loaded.",PLUGIN_VERSION);
	LogToFile(gpanFishyLogFile,"Strafe AC ver %s loaded.",PLUGIN_VERSION);
	
	GetPlayerNamesAndAuths();
	GetCurrentMap(gpanCurrentMap,sizeof(gpanCurrentMap));
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

//-------------------------------------------------------------------------
// Game functions/callbacks
//-------------------------------------------------------------------------
public evPlayerJump(Handle:ahEvent, const String:apanName[], bool:aeDontBroadcast)
{
	new lnClient = GetClientOfUserId(GetEventInt(ahEvent, "userid"));
	
	if(!IsFakeClient(lnClient) && gaePlayerInJump[lnClient] == false)
	{
		gaePlayerInJump[lnClient] = true;
		ganPlayerStartJumpTick[lnClient] = gnTick;
		garPlayerStartJumpEyeYaw[lnClient] = GetClientEyeYaw(lnClient);
		GetEntPropVector(lnClient, Prop_Send, "m_vecOrigin", gaarPlayerStartJumpPos[lnClient]);
	}
}

public OnClientDisconnect(anClient)
{
	ResetClientGlobals(anClient);
}

public OnClientAuthorized(anClient, const String:apanAuth[])
{
	ResetClientGlobals(anClient);
	ganPlayerHyperStrafeStrikes[anClient] = 0;
	GetClientName(anClient,gpanPlayerName[anClient],MAX_LEN_PLAYER_NAME);
	GetClientAuthString(anClient,gpanPlayerAuth[anClient],MAX_LEN_PLAYER_AUTH);
	
	ganFishyCount[anClient] = 0;
	ganFishyLowCount[anClient] = 0;
	ganFishyCountMax[anClient] = 0;
	ganFishyLowCountMax[anClient] = 0;
}

public OnMapStart()
{
	GetCurrentMap(gpanCurrentMap,sizeof(gpanCurrentMap));
}

public OnGameFrame()
{
	decl pnClient;
	gnTick++;
	
	if(gnTick < 0)
	{
		gnTick = 0;
	}
	
	for(pnClient=1;pnClient<=MaxClients;pnClient++)
	{
		if(gaePlayerInJump[pnClient] == true && IsClientConnected(pnClient) && 
		   IsPlayerAlive(pnClient) && !IsFakeClient(pnClient))
		{
			GetPlayerData(pnClient);
			
			if(IsJumpLandedAndValid(pnClient) == true)
			{
				JumpLandedProcessing(pnClient);
				ResetClientGlobals(pnClient);
			}
		}
	}
}

public Action:OnPlayerRunCmd(anClient, &apButtons, &apImpulse, Float:arVel[3], Float:arAngles[3], &apWeapon)
{
	if(IsPlayerAlive(anClient) && !IsFakeClient(anClient))
	{
		UpdateClientButton(anClient,apButtons,IN_JUMP,eeButtonJump);
		UpdateClientButton(anClient,apButtons,IN_DUCK,eeButtonDuck);
		UpdateClientButton(anClient,apButtons,IN_MOVELEFT,eeButtonL);
		UpdateClientButton(anClient,apButtons,IN_MOVERIGHT,eeButtonR);
	}
	
	return Plugin_Continue;
}

//-------------------------------------------------------------------------
// Main plugin functions
//-------------------------------------------------------------------------
bool:IsLongJumpLegit(anClient,&teCheatRule:aeRule)
{
	new lnFlags = GetFishyBehaviorFlags(anClient);
	new bool:leReturn = true;
		
	if(lnFlags != JUMP_NOT_FISHY)
	{
		//PrintToConsole(1,
		//LogDebug("tick= %1.4f | %1.4f ... eye= %1.4f | %1.4f ... move= %1.4f ... both= %1.4f ... none= %1.4f ... eyed = %1.4f",garData[anClient][I_AVG][I_TICK],garData[anClient][I_STD][I_TICK],garData[anClient][I_AVG][I_EYE],garData[anClient][I_STD][I_EYE],garData[anClient][I_AVG][I_MOVE],garData[anClient][I_AVG][I_BOTH],garData[anClient][I_AVG][I_NONE],garData[anClient][I_AVG][I_EYED]);

		if(lnFlags&FISHY_PERF_JUMP && lnFlags&FISHY_PERF_EYE && lnFlags&FISHY_EYE_STD && lnFlags&FISHY_TICKS_STD)
		{
			leReturn = false;
			aeRule = eeCheatPattern1;
		}
		else if(lnFlags&FISHY_PERF_JUMP && lnFlags&FISHY_PERF_EYE && lnFlags&FISHY_EYE_STD)
		{
			leReturn = false;
			aeRule = eeCheatPattern2;
		}
		else if(lnFlags&FISHY_PERF_JUMP && lnFlags&FISHY_PERF_EYE)
		{
			leReturn = false;
			aeRule = eeCheatPattern3;
		}
		else if(lnFlags&FISHY_PERF_JUMP && lnFlags&FISHY_PRO_EYE)
		{
			ganFishyCount[anClient]++;
			ganLastFishyTick[anClient] = gnTick;
			
			if(ganFishyCount[anClient] >= MAX_FISHY_JUMPS_IN_INTERVAL_FOR_CHEAT)
			{
				leReturn = false;
				aeRule = eeCheatPattern4;
			}
			
			if(ganFishyCount[anClient] > ganFishyCountMax[anClient])
			{
				ganFishyCountMax[anClient] = ganFishyCount[anClient];
			}
			
			HandleFishyJump(anClient);
		}
		else if(lnFlags&FISHY_PERF_JUMP && lnFlags&FISHY_LOW_EYE)
		{
			ganFishyLowCount[anClient]++;
			ganLastFishyLowTick[anClient] = gnTick;
			
			if(ganFishyLowCount[anClient] >= MAX_FISHY_LOW_JUMPS_IN_INTERVAL_FOR_CHEAT)
			{
				leReturn = false;
				aeRule = eeCheatPattern5;
			}
			
			if(ganFishyLowCount[anClient] > ganFishyLowCountMax[anClient])
			{
				ganFishyLowCountMax[anClient] = ganFishyLowCount[anClient];
			}
			
			HandleFishyJump(anClient);
		}
	}
	
	return leReturn;
}

CheckForFishyCountReset(anClient)
{
	if(gnTick > ganLastFishyTick[anClient] + FISHY_INTERVAL_RESET_PRO_TICKS)
	{
		ganFishyCount[anClient] = 0;
	}
	
	if(gnTick > ganLastFishyLowTick[anClient] + FISHY_INTERVAL_RESET_LOW_TICKS)
	{
		ganFishyLowCount[anClient] = 0;
	}
}

GetFishyBehaviorFlags(anClient)
{
	new lnNumStrafes = ganStrafeCount[anClient];
	new lnFlags = 0;
	
	garData[anClient][I_AVG][I_TICK] = CalcMean(gaarTicksPerStrafe[anClient],lnNumStrafes,true);

	if(lnNumStrafes > MIN_CHEAT_STRAFE_THRESH && 
	   garData[anClient][I_AVG][I_TICK] < MAX_CHEAT_TICKS_PER_STRAFE)
	{
		garData[anClient][I_AVG][I_EYE] = CalcMean(gaarStrafeEyeYawDeltaStdDev[anClient],lnNumStrafes,true);
		garData[anClient][I_AVG][I_MOVE] = CalcMean(gaarStrafeGoodMovePct[anClient],lnNumStrafes,true);
		garData[anClient][I_AVG][I_EYED] = CalcMean(gaarStrafeGoodEyeMovePct[anClient],lnNumStrafes,true);
		garData[anClient][I_AVG][I_BOTH] = CalcMean(gaarStrafeHoldBothPct[anClient],lnNumStrafes,true);
		garData[anClient][I_AVG][I_NONE] = CalcMean(gaarStrafeHoldNonePct[anClient],lnNumStrafes,true);
		
		garData[anClient][I_STD][I_TICK] = CalcStdDev(gaarTicksPerStrafe[anClient],lnNumStrafes,true);
		garData[anClient][I_STD][I_EYE] = CalcStdDev(gaarStrafeEyeYawDeltaStdDev[anClient],lnNumStrafes,true);
		
		if(garData[anClient][I_STD][I_TICK] < MAX_FISHY_TICKS_STD_DEV)
		{
			lnFlags |= FISHY_TICKS_STD;
		}
		
		if(garData[anClient][I_STD][I_EYE] < MAX_FISHY_EYE_STD_DEV)
		{
			lnFlags |= FISHY_EYE_STD;
		}
		
		if(garData[anClient][I_AVG][I_EYED] >= MAX_FISHY_PERF_EYE_MEAN)
		{
			lnFlags |= FISHY_PERF_EYE;
		}
		
		if(garData[anClient][I_AVG][I_EYED] > MAX_FISHY_PRO_EYE_MEAN)
		{
			lnFlags |= FISHY_PRO_EYE;
		}
		
		if(garData[anClient][I_AVG][I_EYED] > MAX_FISHY_LOW_EYE_MEAN)
		{
			lnFlags |= FISHY_LOW_EYE;
		}
		
		if(garData[anClient][I_AVG][I_MOVE] >= MIN_CHEAT_STRAFE_MOVE_THRESH &&
	       garData[anClient][I_AVG][I_BOTH] < FLOAT_SUB_ZERO_THRESH &&
	       garData[anClient][I_AVG][I_NONE] < FLOAT_SUB_ZERO_THRESH)
		{
			lnFlags |= FISHY_PERF_JUMP;
		}
	}
	
	return lnFlags;
}

JumpLandedProcessing(anClient)
{
	decl Float:parPlayerEndJumpPos[3];
	new teCheatRule:leCheatRule;
	
	//Process the last strafe
	if(ganStrafeCount[anClient] > 0)
	{
		ProcessStrafeStats(anClient,ganStrafeCount[anClient] - 1);
	}
	
	GetEntPropVector(anClient, Prop_Send, "m_vecOrigin", parPlayerEndJumpPos);
	garJumpDistance[anClient] = CalculateJumpDistance(gaarPlayerStartJumpPos[anClient],parPlayerEndJumpPos);
	
	if(garJumpDistance[anClient] > LJ_DIST_PROC_THRESHOLD)
	{
		CheckForFishyCountReset(anClient);
	
		if(IsLongJumpLegit(anClient,leCheatRule) == false)
		{
			HandleStrafeCheat(anClient,leCheatRule,garJumpDistance[anClient]);
		}
		
		//LogDebug("%3.2f lj, %s, tick= %1.4f|%1.4f, eye= %1.4f|%1.4f, move= %1.4f, both= %1.4f, none= %1.4f, look = %1.4f",
		//	garJumpDistance[anClient],"no cheat",
		//	garData[anClient][I_AVG][I_TICK],garData[anClient][I_STD][I_TICK],
		//	garData[anClient][I_AVG][I_EYE],garData[anClient][I_STD][I_EYE],
		//	garData[anClient][I_AVG][I_MOVE],garData[anClient][I_AVG][I_BOTH],
		//	garData[anClient][I_AVG][I_NONE],garData[anClient][I_AVG][I_EYED]);
		
		//LogDebug("%f jump landed, took %d ticks, %d strafes",garJumpDistance[anClient],ganPlayerJumpHangtimeTicks[anClient],ganStrafeCount[anClient]);
	}
}

bool:IsJumpLandedAndValid(anClient)
{
	new bool:leReturn = false;

	if(gaePlayerOnGround[anClient] == true &&
	   ganPlayerJumpHangtimeTicks[anClient] <= LONG_JUMP_LENGTH_TICKS &&
	   ganPlayerJumpHangtimeTicks[anClient] >= BHOP_JUMP_LENGTH_TICKS)
	{
		leReturn = true;
	}
	
	return leReturn;
}

GetPlayerData(anClient)
{
	new lnFlags = GetEntityFlags(anClient);
	
	//On ground flag
	if(lnFlags & FL_ONGROUND)
	{
		gaePlayerOnGround[anClient] = true;
	}
	else
	{
		gaePlayerOnGround[anClient] = false;
	}
	
	//Player strafe directions
	garPlayerNormalizedEyeYaw[anClient] = GetNormalizedClientEyeYaw(anClient);
	gaePlayerStrafeDir[anClient] = GetPlayerMoveStrafeDir(anClient);
	gaePlayerEyeDir[anClient] = GetPlayerEyeStrafeDir(anClient);
	
	//Jump hangtime
	ganPlayerJumpHangtimeTicks[anClient] = gnTick - ganPlayerStartJumpTick[anClient];
	
	//Cancel the jump analysis if it is longer than a standard LJ
	if(ganPlayerJumpHangtimeTicks[anClient] > LONG_JUMP_LENGTH_TICKS)
	{
		CancelPlayerJump(anClient);
	}
	else if(gaePlayerOnGround[anClient] == false)
	{
		GetPlayerStrafeData(anClient);
	}
}

bool:IsNewStrafe(anClient)
{
	new bool:leIsNewStrafe = false;
	
	if(gaePlayerStrafeDir[anClient] != eeStrafeBoth)
	{
		if(gaaeButtonHolds[anClient][eeButtonL] == 1 && gaePrevStrafeDir[anClient] != eeStrafeLeft)
		{
			gaeThisStrafeDir[anClient] = eeStrafeLeft;
			leIsNewStrafe = true;
		}
		else if(gaaeButtonHolds[anClient][eeButtonR] == 1 && gaePrevStrafeDir[anClient] != eeStrafeRight)
		{
			gaeThisStrafeDir[anClient] = eeStrafeRight;
			leIsNewStrafe = true;
		}
	}
	
	return leIsNewStrafe;
}

ProcessStrafeStats(anClient,anStrafeIndex)
{
	new lnNumTicks = RoundToFloor(gaarTicksPerStrafe[anClient][anStrafeIndex]);
	
	if(lnNumTicks > 0)
	{
		gaarStrafeEyeYawDeltaStdDev[anClient][anStrafeIndex] = 
			CalcEyeYawDeltaStdDev(gaarStrafesEyeYaws[anClient],lnNumTicks);
		
		gaarStrafeGoodMovePct[anClient][anStrafeIndex] = 
			gaarStrafeGoodMoveDirTickSum[anClient] / float(lnNumTicks);
		
		if(lnNumTicks > 1)
		{
			gaarStrafeGoodEyeMovePct[anClient][anStrafeIndex] = 
				gaarStrafeGoodEyeDirTickSum[anClient] / float(lnNumTicks - 1);
		}
		else
		{
			gaarStrafeGoodEyeMovePct[anClient][anStrafeIndex] = 0.0;
		}
		
		gaarStrafeHoldBothPct[anClient][anStrafeIndex] = 
			gaarStrafeHoldingBothSum[anClient] / float(lnNumTicks);
		
		gaarStrafeHoldNonePct[anClient][anStrafeIndex] = 
			gaarStrafeHoldingNoneSum[anClient] / float(lnNumTicks);
	}
	else
	{
		gaarStrafeEyeYawDeltaStdDev[anClient][anStrafeIndex] = 10.0;
		gaarStrafeGoodMovePct[anClient][anStrafeIndex] = 0.0;
		gaarStrafeHoldBothPct[anClient][anStrafeIndex] = 1.0;
		gaarStrafeHoldNonePct[anClient][anStrafeIndex] = 1.0;
		
	}
		
	//LogDebug("[%d] ticks=%2.1f,stdyaw=%1.2f,move=%1.2f,both=%1.2f,none=%1.2f,eyedir=%f",
	//	anStrafeIndex,
	//	gaarTicksPerStrafe[anClient][anStrafeIndex],
	//	gaarStrafeEyeYawDeltaStdDev[anClient][anStrafeIndex],
	//	gaarStrafeGoodMovePct[anClient][anStrafeIndex],
	//	gaarStrafeHoldBothPct[anClient][anStrafeIndex],
	//	gaarStrafeHoldNonePct[anClient][anStrafeIndex],
	//	gaarStrafeGoodEyeMovePct[anClient][anStrafeIndex]);
}

GetPlayerStrafeData(anClient)
{
	new lnStrafeIndex = ganStrafeCount[anClient] - 1;

	if(IsNewStrafe(anClient) == true)
	{
		ganStrafeCount[anClient]++;
		lnStrafeIndex = ganStrafeCount[anClient] - 1;
		
		gaePrevStrafeDir[anClient] = gaeThisStrafeDir[anClient];
		
		if(lnStrafeIndex > 1)
		{
			ProcessStrafeStats(anClient,lnStrafeIndex-1);
		}
		
		if(ganStrafeCount[anClient] == MAX_STRAFES)
		{
			HandleHyperStrafe(anClient);
		}
				
		ResetStrafeData(anClient,lnStrafeIndex);
	}
	
	if(ganStrafeCount[anClient] > 0)
	{
		new lnTickIndex = RoundToFloor(gaarTicksPerStrafe[anClient][lnStrafeIndex]);
	
		if(gaePlayerStrafeDir[anClient] == eeStrafeBoth)
		{
			gaarStrafeHoldingBothSum[anClient] += 1.0;
		}
		else if(gaePlayerStrafeDir[anClient] == eeStrafeNone)
		{
			gaarStrafeHoldingNoneSum[anClient] += 1.0;
		}
		
		if(lnTickIndex < MAX_TICKS_PER_STRAFE)
		{
			gaarStrafesEyeYaws[anClient][lnTickIndex] = 
				garPlayerNormalizedEyeYaw[anClient];

			if(gaeThisStrafeDir[anClient] == gaePlayerStrafeDir[anClient])
			{
				gaarStrafeGoodMoveDirTickSum[anClient] += 1.0;
			}
			
			//Ignore the first tick
			if(lnTickIndex > 0 && gaeThisStrafeDir[anClient] == gaePlayerEyeDir[anClient])
			{
				gaarStrafeGoodEyeDirTickSum[anClient] += 1.0;
			}
				
			gaarTicksPerStrafe[anClient][lnStrafeIndex] += 1.0;
		}
	}
}

CancelPlayerJump(anClient)
{
	ResetClientGlobals(anClient);
}

//-------------------------------------------------------------------------
// Data printout functions
//-------------------------------------------------------------------------
public Action:cbPrintJumpStats(anClient, ahArgs)
{
	decl Float:parPlayerPos[3];
	
	for(new i=1;i<=MaxClients;i++)
	{
		if(IsClientConnected(i) && IsClientAuthorized(i) &&
		   IsPlayerAlive(i) && GetClientTeam(i) > 1)
		{
			GetEntPropVector(i, Prop_Send, "m_vecOrigin", parPlayerPos);
		
			PrintToConsole(anClient,
				"%s (%s), %d strafe %3.2f lj, tick(%1.2f|%1.2f) eye(%1.2f|%1.2f) mov(%1.3f|%1.3f|%1.3f) lk(%1.3f) warn(%d/%d|%d/%d) (%s: %3.1f,%3.1f,%3.1f)",
				gpanPlayerName[anClient],gpanPlayerAuth[anClient],
				ganStrafeCount[anClient],garJumpDistance[anClient],
				garData[anClient][I_AVG][I_TICK],garData[anClient][I_STD][I_TICK],
				garData[anClient][I_AVG][I_EYE],garData[anClient][I_STD][I_EYE],
				garData[anClient][I_AVG][I_MOVE],garData[anClient][I_AVG][I_BOTH],
				garData[anClient][I_AVG][I_NONE],garData[anClient][I_AVG][I_EYED],
				ganFishyLowCount[anClient],ganFishyLowCountMax[anClient],
				ganFishyCount[anClient],ganFishyCountMax[anClient],
				gpanCurrentMap,parPlayerPos[0],parPlayerPos[1],parPlayerPos[2]);
		}
	}
    
	return Plugin_Handled;
}

//-------------------------------------------------------------------------
// Cheater handling functions
//-------------------------------------------------------------------------
HandleHyperStrafe(anClient)
{
	LogToFile(gpanLogFile,"%s (%s) slayed for hyper-strafe.",
		gpanPlayerName[anClient],gpanPlayerAuth[anClient]);
		
	//PrintToChatAll("\x04[Anti-cheat] \x03%s (%s) used strafe cheat.",gpanPlayerName[anClient],gpanPlayerAuth[anClient]);

	ganPlayerHyperStrafeStrikes[anClient]++;
	
	if(ganPlayerHyperStrafeStrikes[anClient] >= HYPER_STRAFE_DETS_FOR_BAN)
	{
		#if DO_BANS == 1
		if(GetConVarInt(ghUseSourceBans) == 1)
		{
			ServerCommand("sm_ban #%d %d %s",GetClientUserId(anClient),HYPER_STRAFE_BAN_TIME_IN_MINUTES,"Temp hyperstrafe ban");
			KickClientIfValid(anClient);
		}
		else
		{
			BanClient(anClient,HYPER_STRAFE_BAN_TIME_IN_MINUTES,BANFLAG_AUTO,"Strafe cheating","Temporarily banned for strafe cheats");
		}
		#endif
	
		LogToFile(gpanLogFile,"Banned %s (%s) for %d minutes due to hyper-strafe.",
			gpanPlayerName[anClient],gpanPlayerAuth[anClient],HYPER_STRAFE_BAN_TIME_IN_MINUTES);
	}
	else
	{
		ForcePlayerSuicide(anClient);
	}
	
	ResetClientGlobals(anClient);
}

HandleStrafeCheat(anClient,teCheatRule:aeCheatRule,Float:arJumpDistance)
{
	decl String:paanCheatRules[eeCheatPatternMax][32] = { "Pattern1", "Pattern2", "Pattern3", "Pattern4", "Pattern5" };
	decl Float:parPlayerPos[3];
	GetEntPropVector(anClient, Prop_Send, "m_vecOrigin", parPlayerPos);
	
	//PrintToChatAll("\x04[Anti-cheat] \x03%s (%s) used strafe cheat.",gpanPlayerName[anClient],gpanPlayerAuth[anClient]);
	
	LogToFile(gpanLogFile,
		"%s (%s), %s,%d strafe %3.2f lj, tick(%1.2f|%1.2f) eye(%1.2f|%1.2f) mov(%1.3f|%1.3f|%1.3f) lk(%1.3f) warn(%d/%d|%d/%d) (%s: %3.1f,%3.1f,%3.1f)",
		gpanPlayerName[anClient],gpanPlayerAuth[anClient],paanCheatRules[aeCheatRule],
		ganStrafeCount[anClient],arJumpDistance,
		garData[anClient][I_AVG][I_TICK],garData[anClient][I_STD][I_TICK],
		garData[anClient][I_AVG][I_EYE],garData[anClient][I_STD][I_EYE],
		garData[anClient][I_AVG][I_MOVE],garData[anClient][I_AVG][I_BOTH],
		garData[anClient][I_AVG][I_NONE],garData[anClient][I_AVG][I_EYED],
		ganFishyLowCount[anClient],ganFishyLowCountMax[anClient],
		ganFishyCount[anClient],ganFishyCountMax[anClient],
		gpanCurrentMap,parPlayerPos[0],parPlayerPos[1],parPlayerPos[2]);
	
	//ForcePlayerSuicide(anClient);
	ResetClientGlobals(anClient);

	#if DO_BANS == 1
	if(GetConVarInt(ghUseSourceBans) == 1)
	{
		ServerCommand("sm_ban #%d %d %s",GetClientUserId(anClient),0,"Strafe cheat");
		KickClientIfValid(anClient);
	}
	else
	{
		//BANFLAG_AUTHID|BANFLAG_IP
		BanClient(anClient,0,BANFLAG_AUTO,"Strafe cheating","Banned for strafe cheat");
	}
	#endif
	
	//LogDebug("%s (%s), %s,%3.2f lj, tick(%1.4f|%1.4f) eye(%1.4f|%1.4f) mov(%1.4f|%1.4f|%1.4f) lk(%1.4f) warn(%d|%d)",
	//	gpanPlayerName[anClient],gpanPlayerAuth[anClient],paanCheatRules[aeCheatRule],arJumpDistance,
	//	garData[anClient][I_AVG][I_TICK],garData[anClient][I_STD][I_TICK],
	//	garData[anClient][I_AVG][I_EYE],garData[anClient][I_STD][I_EYE],
	//	garData[anClient][I_AVG][I_MOVE],garData[anClient][I_AVG][I_BOTH],
	//	garData[anClient][I_AVG][I_NONE],garData[anClient][I_AVG][I_EYED],
	//	ganFishyLowCountMax[anClient],ganFishyCountMax[anClient]);
}

HandleFishyJump(anClient)
{
	decl Float:parPlayerPos[3];
	GetEntPropVector(anClient, Prop_Send, "m_vecOrigin", parPlayerPos);
	
	LogToFile(gpanFishyLogFile,
		"%s (%s), FISHY,%d strafe %3.2f lj, tick(%1.2f|%1.2f) eye(%1.2f|%1.2f) mov(%1.3f|%1.3f|%1.3f) lk(%1.3f) warn(%d/%d|%d/%d) (%s: %3.1f,%3.1f,%3.1f)",
		gpanPlayerName[anClient],gpanPlayerAuth[anClient],
		ganStrafeCount[anClient],garJumpDistance[anClient],
		garData[anClient][I_AVG][I_TICK],garData[anClient][I_STD][I_TICK],
		garData[anClient][I_AVG][I_EYE],garData[anClient][I_STD][I_EYE],
		garData[anClient][I_AVG][I_MOVE],garData[anClient][I_AVG][I_BOTH],
		garData[anClient][I_AVG][I_NONE],garData[anClient][I_AVG][I_EYED],
		ganFishyLowCount[anClient],ganFishyLowCountMax[anClient],
		ganFishyCount[anClient],ganFishyCountMax[anClient],
		gpanCurrentMap,parPlayerPos[0],parPlayerPos[1],parPlayerPos[2]);
}

KickClientIfValid(anClient)
{
	if(IsClientAuthorized(anClient) && IsClientInGame(anClient))
	{
		KickClient(anClient);
	}
}

//-------------------------------------------------------------------------
// Getter/setter methods
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

Float:CalcEyeYawDeltaStdDev(Float:aarEyeYaw[],anNumSamples)
{
	decl Float:parEyeYawDelta[MAX_TICKS_PER_STRAFE];
	new Float:lrReturn = 10.0;
	
	//Exclude first tick of strafe
	for(new i=1;i<anNumSamples;i++)
	{
		parEyeYawDelta[i-1] = aarEyeYaw[i] - aarEyeYaw[i-1];
	}
	
	if(anNumSamples > 2)
	{
		lrReturn = CalcStdDev(parEyeYawDelta,anNumSamples - 1);
	}
	
	return lrReturn;
}

ResetStrafeData(anClient,anStrafeIndex)
{
	gaarTicksPerStrafe[anClient][anStrafeIndex] = 0.0;
	gaarStrafeHoldingBothSum[anClient] = 0.0;
	gaarStrafeHoldingNoneSum[anClient] = 0.0;
	gaarStrafeGoodMoveDirTickSum[anClient] = 0.0;
	gaarStrafeGoodEyeDirTickSum[anClient] = 0.0;
}

public ResetClientGlobals(anClient)
{
	//gaaeButtonHolds shouldn't need clearing
	gaePlayerInJump[anClient] = false;
	ganPlayerStartJumpTick[anClient] = 0;
	gaePlayerOnGround[anClient] = false;
	gaeThisStrafeDir[anClient] = eeStrafeNone;
	gaePrevStrafeDir[anClient] = eeStrafeNone;
	ganStrafeCount[anClient] = 0;
}

Float:GetClientEyeYaw(anClient)
{
	decl Float:parEyeAngles[3];

	GetClientEyeAngles(anClient,parEyeAngles);
	
	return parEyeAngles[EYE_YAW_IDX];
}

teStrafeDir:GetPlayerEyeStrafeDir(anClient)
{
	decl Float:parPrevPlayerNormalizedEyeYaw[MAXPLAYERS+1];
	
	new Float:lrEyeYawDelta = 
		parPrevPlayerNormalizedEyeYaw[anClient] - garPlayerNormalizedEyeYaw[anClient];
	
	parPrevPlayerNormalizedEyeYaw[anClient] = garPlayerNormalizedEyeYaw[anClient];
	
	if(lrEyeYawDelta < -EYE_YAW_DELTA_STAFE_MIN)
	{
		return eeStrafeLeft;
	}
	else if(lrEyeYawDelta > EYE_YAW_DELTA_STAFE_MIN)
	{
		return eeStrafeRight;
	}
	else
	{
		return eeStrafeNone;
	}
}

teStrafeDir:GetPlayerMoveStrafeDir(anClient)
{
	if(gaaeButtonHolds[anClient][eeButtonL] == 1 && gaaeButtonHolds[anClient][eeButtonR] != 1)
	{
		return eeStrafeLeft;
	}
	else if(gaaeButtonHolds[anClient][eeButtonL] != 1 && gaaeButtonHolds[anClient][eeButtonR] == 1)
	{
		return eeStrafeRight;
	}
	else if(gaaeButtonHolds[anClient][eeButtonL] == 1 && gaaeButtonHolds[anClient][eeButtonR] == 1)
	{
		return eeStrafeBoth;
	}
	else
	{
		return eeStrafeNone;
	}
}

UpdateClientButton(anClient,anButtons,anKey,teButtonType:aeButtonType)
{
	if(anButtons & anKey)
	{
		gaaeButtonHolds[anClient][aeButtonType] = true;
	}
	else
	{
		gaaeButtonHolds[anClient][aeButtonType] = false;
	}
}

Float:GetNormalizedClientEyeYaw(anClient)
{
	return FloatMod(GetClientEyeYaw(anClient) + (90.0 - garPlayerStartJumpEyeYaw[anClient]),180.0);
}

//-------------------------------------------------------------------------
// Generic math functions
//-------------------------------------------------------------------------
Float:CalculateJumpDistance(Float:aarStart[3],Float:aarEnd[3])
{
	return GetVectorDistance(aarStart,aarEnd) + 32.0;
}

//Note this function only handles positive modulo
Float:FloatMod(Float:arX,Float:arY)
{
	while(arX < arY)
	{
		arX += arY;
	}
	
	while(arX >= arY)
	{
		arX -= arY;
	}
	
	return arX;
}

Float:CalcMean(Float:aarValues[],anNumValues,bool:aeExcludeFirstSample = false)
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
		lrSum += aarValues[i];
	}
	
	//LogDebug("CalcMean: %f/%f = %f",lrSum,float(lnProcessedSamples),lrSum / float(lnProcessedSamples));
	
	return lrSum / float(lnProcessedSamples);
}

Float:FloatSquare(Float:arVal)
{
	return arVal * arVal;
}

Float:CalcStdDev(Float:aarValues[],anNumValues,bool:aeExcludeFirstSample = false)
{
	new Float:lrDeviationSqSum = 0.0;
	new Float:lrMean = CalcMean(aarValues,anNumValues,aeExcludeFirstSample);
	new lnStartIdx = 0;
	new lnProcessedSamples = anNumValues;
	
	if(aeExcludeFirstSample == true && anNumValues > 2)
	{
		lnStartIdx = 1;
		lnProcessedSamples = anNumValues - 1;
	}
	
	for(new i=lnStartIdx;i<anNumValues;i++)
	{
		lrDeviationSqSum += FloatSquare(aarValues[i] - lrMean);
	}
	
	return SquareRoot(lrDeviationSqSum / float(lnProcessedSamples - 1));
}



