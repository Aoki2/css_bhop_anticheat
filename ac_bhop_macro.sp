#pragma semicolon 1
#include <sourcemod>
#include <sdktools>

#define LOG_DEBUG_ENABLE 0
#define LOG_TO_CHAT 0
#define LOG_TO_SERVER 0
#define LOG_TO_FILE 0

#define PLUGIN_VERSION "1.1"

#define SUPPRESS_MSG_LIMIT 3
#define MSG_RATE_LIMITER (100 * 20) //20 seconds

#define MAX_CHEATER_VELOCITY (325.0)
#define CHEATING_AVG_JUMP_THRESH (20.0)
#define CHEATING_AVG_JUMP_TICK_GAP (2.7)

#define NOT_BHOPPING_TICKS 250
#define NUM_TICKS_LIMIT_SPEED 1

//Number of jumps to average to get avg velocity
#define AVG_VELOCITY_SAMPLE_WINDOW (10.0)

//Number of average jumps needed to check for jump tick gap
#define JUMP_GAP_CHECK_AVG_JUMPS_GATE (7.0)
#define AVG_JUMPS_TO_CHECK_JUMP_RATE (8.0)

#define NUM_OFFENSES_TO_LIMIT_SPEED (6)

#define OFFENSE_FREQ_FORGIVE_TICKS (100 * 2) //2 seconds

#define DEFAULT_AVG_TICKS_PER_JUMP (3.5)
#define TICKS_PER_JUMP_APPROX (60.0)

public Plugin:myinfo = 
{
    name = "Bhop macro anti-cheat",
    author = "Aoki",
    description = "Bhop macro/hyperscroll detection",
    version = PLUGIN_VERSION,
    url = ""
}

//Globals variables
new Float:gar3AvgJumps[MAXPLAYERS+1] = {1.0, ...};
new Float:garAvgVelocity[MAXPLAYERS+1] = {250.0, ...};
new ganReducedSpeedPrints[MAXPLAYERS+1] = {0, ...};
new ganReducedSpeedPrintTick[MAXPLAYERS+1] = {0, ...};
new ganJumps[MAXPLAYERS+1] = {0, ...};
new String:gpanLogFile[127];
new gnTick = 0;
new ganPrevJumpTick[MAXPLAYERS+1] = {0, ...};
new ganTicksToLimitSpeed[MAXPLAYERS+1] = {0, ...};
new Float:garAvgTicksSinceLastJump[MAXPLAYERS + 1] = { 0.0, ... };
new ganNumOffenses[MAXPLAYERS+1] = {0, ...};
new ganPrevOffenseTick[MAXPLAYERS+1] = {0, ...};
new ganMostOffenses[MAXPLAYERS+1] = {0, ...};

public OnPluginStart()
{   
	BuildPath(Path_SM, gpanLogFile, sizeof(gpanLogFile), "logs/ac_macro.log");
	
	CreateConVar("ac_bh_macro_version", PLUGIN_VERSION, "Bhop macro AC version", FCVAR_PLUGIN|FCVAR_NOTIFY|FCVAR_REPLICATED);
	HookEvent("player_jump", evPlayerJump, EventHookMode_Post);
	RegAdminCmd("jc_stats", cbPrintJumpStats, ADMFLAG_SLAY, "jc_stats");
	
	LogToFile(gpanLogFile,"BH macro AC ver %s loaded.",PLUGIN_VERSION);
}

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

public evPlayerJump(Handle:ahEvent, const String:apanName[], bool:aeDontBroadcast)
{
	new lnClient = GetClientOfUserId(GetEventInt(ahEvent, "userid"));
	
	if(!IsFakeClient(lnClient))
	{
		gar3AvgJumps[lnClient] = ( gar3AvgJumps[lnClient] * 2.0 + float(ganJumps[lnClient]) ) / 3.0;
		
		decl Float:larXYVel[3];
		GetEntPropVector(lnClient, Prop_Data, "m_vecVelocity", larXYVel);
		larXYVel[2] = 0.0;
		new Float:lrXYVelocity = GetVectorLength(larXYVel);
		
		garAvgVelocity[lnClient] = ((garAvgVelocity[lnClient] * 
			(AVG_VELOCITY_SAMPLE_WINDOW - 1.0)) + lrXYVelocity) / AVG_VELOCITY_SAMPLE_WINDOW;
		
		if(gnTick - ganPrevJumpTick[lnClient] > NOT_BHOPPING_TICKS)
		{
			gar3AvgJumps[lnClient] = 0.0;
		}
		
		//Stop players who have too many jump commands per jump
		if(gar3AvgJumps[lnClient] > CHEATING_AVG_JUMP_THRESH)
		{
			TriggerPlayerSpeedLimit(lnClient);
		}
		
		ganPrevJumpTick[lnClient] = gnTick;
		ganJumps[lnClient] = 0;
		garAvgTicksSinceLastJump[lnClient] = DEFAULT_AVG_TICKS_PER_JUMP;
	}
}

public bool:CheckOffenseFrequency(anClient)
{
	new bool:leReturn = false;
	
	//if there have been too many offenses, the player will be limited and offense count keeps incrementing
	if(ganNumOffenses[anClient] >= NUM_OFFENSES_TO_LIMIT_SPEED)
	{
		leReturn = true;
	}
	//else if this is a new jump a new offense can register
	else if(gnTick - ganPrevOffenseTick[anClient] > TICKS_PER_JUMP_APPROX)
	{
		//only register an offense if they occur frequently
		if(gnTick - ganPrevOffenseTick[anClient] < OFFENSE_FREQ_FORGIVE_TICKS)
		{
			ganNumOffenses[anClient]++;
			LogDebug("[%d]OFFENSE ADDED %d",anClient,ganNumOffenses[anClient]);
			
			if(ganNumOffenses[anClient] > ganMostOffenses[anClient])
			{
				ganMostOffenses[anClient] = ganNumOffenses[anClient];
			}
		}
		else
		{
			ganNumOffenses[anClient] = 0;
			LogDebug("[%d]OFFENSES RESET",anClient);
		}
		
		ganPrevOffenseTick[anClient] = gnTick;
	}
	
	return leReturn;
}

public TriggerPlayerSpeedLimit(anClient)
{
	decl String:ppanPlayerName[92];
	
	//Make sure the player has been triggered enough to limit their speed
	if(CheckOffenseFrequency(anClient) == false)
	{
		return;
	}
	
	if(gnTick - ganReducedSpeedPrintTick[anClient] > MSG_RATE_LIMITER)
	{
		GetClientName( anClient, ppanPlayerName, sizeof(ppanPlayerName));
		ganReducedSpeedPrints[anClient]++;
		
		//Only write to log file once
		if(ganReducedSpeedPrints[anClient] == 1)
		{
			decl String:ppanPlayerAuth[23];
			
			GetClientAuthString(anClient,ppanPlayerAuth,sizeof(ppanPlayerAuth));
			LogToFile(gpanLogFile, "%s (%s) - Avg jumps: %f, Avg vel: %f, Tick gap: %f",
				ppanPlayerName,ppanPlayerAuth,gar3AvgJumps[anClient],
				garAvgVelocity[anClient],garAvgTicksSinceLastJump[anClient]);
		}
		
		if(ganReducedSpeedPrints[anClient] <= SUPPRESS_MSG_LIMIT)
		{
			if(ganReducedSpeedPrints[anClient] == SUPPRESS_MSG_LIMIT)
			{
				PrintToChatAll("\x04[Anti-cheat]\x03 Limiting speed of \x04%s \x03due to macro/hyperscroll detection.  Suppressing further messages.",ppanPlayerName);
			}
			else
			{
				PrintToChatAll("\x04[Anti-cheat]\x03 Limiting speed of \x04%s \x03due to macro/hyperscroll detection.",ppanPlayerName);
			}
		}
		else
		{
			PrintToChat(anClient,"\x04[Anti-cheat]\x03 Your speed is being limited due to macro/hyperscroll detection.");
		}
		
		ganReducedSpeedPrintTick[anClient] = gnTick;
	}
	
	ganTicksToLimitSpeed[anClient] += NUM_TICKS_LIMIT_SPEED;
}

public LimitPlayerSpeed(anClient)
{
	decl Float:prPrevZ;
	
	decl Float:larVel[3];
	GetEntPropVector(anClient, Prop_Data, "m_vecVelocity", larVel);
	prPrevZ = larVel[2];
	larVel[2] = 0.0;
	
	if(GetVectorLength(larVel) > MAX_CHEATER_VELOCITY)
	{
		NormalizeVector(larVel, larVel);
		ScaleVector(larVel, MAX_CHEATER_VELOCITY);
		larVel[2] = prPrevZ;
		TeleportEntity(anClient, NULL_VECTOR, NULL_VECTOR, larVel);
	}
}

public OnClientDisconnect(anClient)
{
	ResetClientGlobals(anClient);
}

public OnClientAuthorized(anClient, const String:apanAuth[])
{
	ResetClientGlobals(anClient);
}

public ResetClientGlobals(anClient)
{
	ganReducedSpeedPrints[anClient] = 0;
	ganReducedSpeedPrintTick[anClient] = 0;
	gar3AvgJumps[anClient] = 0.0;
	garAvgVelocity[anClient] = 0.0;
	ganJumps[anClient] = 0;
	ganPrevJumpTick[anClient] = 0;
	ganTicksToLimitSpeed[anClient] = 0;
	ganNumOffenses[anClient] = 0;
	ganPrevOffenseTick[anClient] = 0;
	ganMostOffenses[anClient] = 0;
}

public OnGameFrame()
{
	decl pnIndex;
	gnTick++;
	
	if(gnTick < 0)
	{
		gnTick = 0;
	}
		
	for(pnIndex=1;pnIndex<MaxClients;pnIndex++)
	{
		if(ganTicksToLimitSpeed[pnIndex]  > 0 && 
		   IsClientConnected(pnIndex) && IsClientAuthorized(pnIndex)  &&
		   IsPlayerAlive(pnIndex) && GetClientTeam(pnIndex) > 1 &&
		   !IsFakeClient(pnIndex))
		{
			LimitPlayerSpeed(pnIndex);
			ganTicksToLimitSpeed[pnIndex]--;
		}
	}
}

public Action:OnPlayerRunCmd(anClient, &apButtons, &apImpulse, Float:arVel[3], Float:arAngles[3], &apWeapon)
{
	static bool:peHoldingJump[MAXPLAYERS + 1];
	static pnLastJumpTick[MAXPLAYERS + 1] = { 0, ... };
	decl Float:lrTicksSinceLastJump;
	
	if(IsPlayerAlive(anClient) && !IsFakeClient(anClient))
	{
		if(apButtons & IN_JUMP)
		{
			if(!peHoldingJump[anClient])
			{
				peHoldingJump[anClient] = true;//started pressing +jump
				ganJumps[anClient]++;
				
				lrTicksSinceLastJump = float(gnTick - pnLastJumpTick[anClient]);
				
				if(lrTicksSinceLastJump > 15.0)
				{
					lrTicksSinceLastJump = 3.5;
				}
				
				garAvgTicksSinceLastJump[anClient] = 
				(garAvgTicksSinceLastJump[anClient] * (JUMP_GAP_CHECK_AVG_JUMPS_GATE - 1.0) + 
					lrTicksSinceLastJump) / 
					JUMP_GAP_CHECK_AVG_JUMPS_GATE;
				
				//LogDebug("last %f, avg %f, 3j %f",lrTicksSinceLastJump,garAvgTicksSinceLastJump[anClient],gar3AvgJumps[anClient]);
				
				//Stop players who have jumps too rapidly
				if(garAvgTicksSinceLastJump[anClient] >= AVG_JUMPS_TO_CHECK_JUMP_RATE &&
				   garAvgTicksSinceLastJump[anClient] <= CHEATING_AVG_JUMP_TICK_GAP &&
				   gar3AvgJumps[anClient] < CHEATING_AVG_JUMP_THRESH)
				{
					TriggerPlayerSpeedLimit(anClient);
				}
				
				pnLastJumpTick[anClient] = gnTick;
			}
		}
		else if(peHoldingJump[anClient]) 
		{
			peHoldingJump[anClient] = false;//released (-jump)
		}
	}

	return Plugin_Continue;
}

public Action:cbPrintJumpStats(anClient, ahArgs)
{
	decl String:ppanPlayerName[92];
	decl String:ppanPlayerAuth[23];

	for(new lnIndex=1;lnIndex<MaxClients;lnIndex++)
	{
		if(IsClientConnected(lnIndex) && IsClientAuthorized(lnIndex) &&
		   IsPlayerAlive(lnIndex) && GetClientTeam(lnIndex) > 1)
		{
			GetClientName( lnIndex, ppanPlayerName, sizeof(ppanPlayerName));
			GetClientAuthString(lnIndex,ppanPlayerAuth,sizeof(ppanPlayerAuth));
			
			PrintToConsole(anClient, "%s (%s) - Avg jumps: %f, Avg vel: %f, Tick gap: %f, Offenses: %d (%d most) ",
				ppanPlayerName,ppanPlayerAuth,gar3AvgJumps[lnIndex],
				garAvgVelocity[lnIndex],garAvgTicksSinceLastJump[lnIndex],
				ganNumOffenses[lnIndex],ganMostOffenses[lnIndex]);
		}
	}
    
	return Plugin_Handled;
}
