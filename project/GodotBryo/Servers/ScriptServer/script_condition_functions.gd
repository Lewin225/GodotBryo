@tool
class_name ScriptConditionFunctions
extends RefCounted

## The FNV condition functions: the Get*/Is* functions a script can call inside
## an expression, and the functions CTDA conditions name by index. Source:
## xEdit's wbConditionFunctions (enginedocs/xEdit/Core/wbDefinitionsFNV.pas),
## indices below 4096; the rest are NVSE extensions, out of scope.
## 338 functions.

## xEdit parameter types by what a parameter's raw CTDA word becomes.
## A placed reference: the reference, 0x14 being the player's.
const REFERENCE_PARAMETERS := ["ptActor", "ptReference"]
## A CELL or WRLD FormID, kept as the int (neither has a resource).
const FORM_ID_PARAMETERS := ["ptCell", "ptWorldSpace"]
## Any other record: its base resource from EsmServer.get_base().
const BASE_PARAMETERS := ["ptACtorBase", "ptActorBase", "ptBaseEffect", "ptBaseObject", "ptCasino", "ptChallenge", "ptClass", "ptEffectItem", "ptEncounterZone", "ptFaction", "ptFormList", "ptFurniture", "ptGlobal", "ptIdleForm", "ptInventoryObject", "ptNote", "ptOwner", "ptPackage", "ptPerk", "ptQuest", "ptRace", "ptRegion", "ptReputation", "ptVoiceType", "ptWeather"]
## An integer (actor value code, sex, stage, variable index, ...).
const INTEGER_PARAMETERS := ["ptActorValue", "ptAlignment", "ptAxis", "ptBodyLocation", "ptCreatureType", "ptCrimeType", "ptCriticalStage", "ptEquipType", "ptFormType", "ptInteger", "ptMenuMode", "ptMiscStat", "ptPlayerAction", "ptQuestObjective", "ptQuestStage", "ptSex", "ptVATSValueFunction", "ptVATSValueParam", "ptVariableName"]

## The player's reference FormID in CTDA Reference fields and parameters. It
## has no ESM record.
const PLAYER_REFERENCE_FORM_ID := 0x14

## Parameter counts by lowercased name, for parsing calls inside expressions.
## The comment on each is its xEdit parameter types.
const ARITIES := {
	"callfunctioncond": 2, # ptFormList, ptInteger
	"canhaveflames": 0, # no parameters
	"challengelocked": 1, # ptChallenge
	"exists": 1, # ptReference
	"getactoraggroradiusviolated": 0, # no parameters
	"getactorcrimeplayerenemy": 0, # no parameters
	"getactorfactionplayerenemy": 0, # no parameters
	"getactorfikstatus": 0, # no parameters
	"getactorsinhigh": 0, # no parameters
	"getactorvalue": 1, # ptActorValue
	"getageclass": 1, # ptActorBase
	"getalarmed": 0, # no parameters
	"getaltperkrank": 2, # ptPerk, ptActor
	"getammoconsumedpercent": 1, # ptInventoryObject
	"getammospeed": 1, # ptInventoryObject
	"getamountsoldstolen": 0, # no parameters
	"getangle": 1, # ptAxis
	"getanimaction": 0, # no parameters
	"getarmorar": 1, # ptInventoryObject
	"getarmordt": 1, # ptInventoryObject
	"getarmorrating": 0, # no parameters
	"getarmorratingupperbody": 0, # no parameters
	"getattackdamage": 1, # ptInventoryObject
	"getattacked": 0, # no parameters
	"getbartergold": 0, # no parameters
	"getbaseactorvalue": 1, # ptActorValue
	"getcannibal": 0, # no parameters
	"getcasinowinningstage": 1, # ptCasino
	"getcauseofdeath": 0, # no parameters
	"getchallengecompleted": 1, # ptChallenge
	"getclassdefaultmatch": 0, # no parameters
	"getclothingvalue": 0, # no parameters
	"getconcussed": 0, # no parameters
	"getcrime": 2, # ptActor, ptCrimeType
	"getcurrentaipackage": 0, # no parameters
	"getcurrentaiprocedure": 0, # no parameters
	"getcurrenthealth": 0, # no parameters
	"getcurrenttime": 0, # no parameters
	"getcurrentweatherpercent": 0, # no parameters
	"getdayofweek": 0, # no parameters
	"getdead": 0, # no parameters
	"getdeadcount": 1, # ptActorBase
	"getdefaultopen": 0, # no parameters
	"getdestroyed": 0, # no parameters
	"getdestructionstage": 0, # no parameters
	"getdetected": 1, # ptActor
	"getdetectionlevel": 1, # ptActor
	"getdialogueemotion": 0, # no parameters
	"getdialogueemotionvalue": 0, # no parameters
	"getdialoguespeaker": 1, # ptActor
	"getdialoguesubject": 1, # ptActor
	"getdialoguetarget": 1, # ptActor
	"getdisabled": 0, # no parameters
	"getdisease": 0, # no parameters
	"getdisposition": 1, # ptActor
	"getdistance": 1, # ptReference
	"getequipped": 1, # ptInventoryObject
	"getequippedcurrenthealth": 1, # ptInteger
	"getequippedweaponcanuseammo": 1, # ptInventoryObject
	"getequippedweaponmodflags": 0, # no parameters
	"getequippedweaponusesammolist": 1, # ptFormList
	"getequiptype": 1, # ptInventoryObject
	"getfactioncombatreaction": 2, # ptFaction, ptFaction
	"getfactionrank": 1, # ptFaction
	"getfactionrankdifference": 2, # ptFaction, ptActor
	"getfactionrelation": 1, # ptActor
	"getfatiguepercentage": 0, # no parameters
	"getforcehitreaction": 0, # no parameters
	"getfriendhit": 0, # no parameters
	"getfurnituremarkerid": 0, # no parameters
	"getglobalvalue": 1, # ptGlobal
	"getgold": 0, # no parameters
	"getgroupmembercount": 0, # no parameters
	"getgrouptargetcount": 0, # no parameters
	"gethasnote": 1, # ptNote
	"getheadingangle": 1, # ptReference
	"gethealth": 1, # ptFormType
	"gethealthpercentage": 0, # no parameters
	"gethitlocation": 0, # no parameters
	"getidledoneonce": 0, # no parameters
	"getignorecrime": 0, # no parameters
	"getignorefriendlyhits": 0, # no parameters
	"getincell": 1, # ptCell
	"getincellparam": 2, # ptCell, ptReference
	"getinfaction": 1, # ptFaction
	"getinsamecell": 1, # ptReference
	"getinworldspace": 1, # ptWorldSpace
	"getinzone": 1, # ptEncounterZone
	"getisalerted": 0, # no parameters
	"getisalignment": 1, # ptAlignment
	"getisclass": 1, # ptClass
	"getisclassdefault": 1, # ptClass
	"getiscreature": 0, # no parameters
	"getiscreaturetype": 1, # ptCreatureType
	"getiscurrentpackage": 1, # ptPackage
	"getiscurrentweather": 1, # ptWeather
	"getisghost": 0, # no parameters
	"getisid": 1, # ptBaseObject
	"getislockbroken": 0, # no parameters
	"getisobjecttype": 1, # ptFormType
	"getisplayablerace": 0, # no parameters
	"getisrace": 1, # ptRace
	"getisreference": 1, # ptReference
	"getissex": 1, # ptSex
	"getisuseditem": 1, # ptBaseObject
	"getisuseditemequiptype": 1, # ptEquipType
	"getisuseditemtype": 1, # ptFormType
	"getisvoicetype": 1, # ptVoiceType
	"getitemcount": 1, # ptInventoryObject
	"getkillingblowlimb": 0, # no parameters
	"getknockedstate": 0, # no parameters
	"getlasthitcritical": 0, # no parameters
	"getlastplayeraction": 0, # no parameters
	"getlevel": 0, # no parameters
	"getlineofsight": 1, # ptReference
	"getlocked": 0, # no parameters
	"getlocklevel": 0, # no parameters
	"getmajorcrimecount": 0, # no parameters
	"getmapmarkervisible": 0, # no parameters
	"getminorcrimecount": 0, # no parameters
	"getnorumors": 0, # no parameters
	"getnumitems": 0, # no parameters
	"getnvsebeta": 0, # no parameters
	"getnvserevision": 0, # no parameters
	"getnvseversion": 0, # no parameters
	"getobjectivecompleted": 2, # ptQuest, ptQuestObjective
	"getobjectivedisplayed": 2, # ptQuest, ptQuestObjective
	"getoffersservicesnow": 0, # no parameters
	"getopenstate": 0, # no parameters
	"getpackagecount": 1, # ptReference
	"getpaired": 2, # ptInventoryObject, ptActorBase
	"getpcenemyoffaction": 1, # ptFaction
	"getpcexpelled": 1, # ptFaction
	"getpcfactionattack": 1, # ptFaction
	"getpcfactionmurder": 1, # ptFaction
	"getpcinfaction": 1, # ptFaction
	"getpcisclass": 1, # ptClass
	"getpcisrace": 1, # ptRace
	"getpcissex": 1, # ptSex
	"getpcmiscstat": 1, # ptMiscStat
	"getperkrank": 2, # ptPerk, ptActor
	"getpermanent": 1, # ptReference
	"getpermanentactorvalue": 1, # ptActorValue
	"getpersuasionnumber": 0, # no parameters
	"getplantedexplosive": 0, # no parameters
	"getplayercontrolsdisabled": 2, # ptInteger, ptInteger
	"getplayerhaslastriddenhorse": 0, # no parameters
	"getplayerteammate": 0, # no parameters
	"getplayerteammatecount": 0, # no parameters
	"getpos": 1, # ptAxis
	"getquestcompleted": 1, # ptQuest
	"getquestrunning": 1, # ptQuest
	"getquestvariable": 2, # ptQuest, ptVariableName
	"getradiationlevel": 0, # no parameters
	"getrandompercent": 0, # no parameters
	"getreputation": 2, # ptReputation, ptInteger
	"getreputationpct": 2, # ptReputation, ptInteger
	"getreputationthreshold": 2, # ptReputation, ptInteger
	"getrespawn": 1, # ptACtorBase
	"getrestrained": 0, # no parameters
	"getsandman": 0, # no parameters
	"getscale": 0, # no parameters
	"getscriptvariable": 2, # ptReference, ptVariableName
	"getsecondspassed": 0, # no parameters
	"getshouldattack": 1, # ptActor
	"getsitting": 0, # no parameters
	"getsleeping": 0, # no parameters
	"getspellusagenum": 1, # ptEffectItem
	"getstage": 1, # ptQuest
	"getstagedone": 2, # ptQuest, ptQuestStage
	"getstartingangle": 1, # ptAxis
	"getstartingpos": 1, # ptAxis
	"gettalkedtopc": 0, # no parameters
	"gettalkedtopcparam": 1, # ptActor
	"gettfc": 0, # no parameters
	"getthreatratio": 1, # ptActor
	"gettimedead": 0, # no parameters
	"gettokenref": 1, # ptFormType
	"gettokenvalue": 1, # ptFormType
	"gettotalpersuasionnumber": 0, # no parameters
	"gettrespasswarninglevel": 0, # no parameters
	"gettype": 1, # ptFormType
	"getunconscious": 0, # no parameters
	"getuseditemactivate": 0, # no parameters
	"getuseditemlevel": 0, # no parameters
	"getvalue": 1, # ptInventoryObject
	"getvampire": 0, # no parameters
	"getvatsbackareafree": 1, # ptReference
	"getvatsbacktargetvisible": 1, # ptReference
	"getvatsfrontareafree": 1, # ptReference
	"getvatsfronttargetvisible": 1, # ptReference
	"getvatsleftareafree": 1, # ptReference
	"getvatslefttargetvisible": 1, # ptReference
	"getvatsmode": 0, # no parameters
	"getvatsrightareafree": 1, # ptReference
	"getvatsrighttargetvisible": 1, # ptReference
	"getvatstargetheight": 0, # no parameters
	"getvatsvalue": 2, # ptVATSValueFunction, ptVATSValueParam
	"getwalkspeed": 0, # no parameters
	"getweaponactionpoints": 1, # ptInventoryObject
	"getweaponaimarc": 1, # ptInventoryObject
	"getweaponammouse": 1, # ptInventoryObject
	"getweaponanimattackmult": 1, # ptInventoryObject
	"getweaponanimjamtime": 1, # ptInventoryObject
	"getweaponanimmult": 1, # ptInventoryObject
	"getweaponanimreloadtime": 1, # ptInventoryObject
	"getweaponanimshotspersec": 1, # ptInventoryObject
	"getweaponanimtype": 0, # no parameters
	"getweaponattackanimation": 1, # ptInventoryObject
	"getweaponbasevatschance": 1, # ptInventoryObject
	"getweaponcanuseammo": 2, # ptInventoryObject, ptInventoryObject
	"getweaponcliprounds": 1, # ptInventoryObject
	"getweaponcritchance": 1, # ptInventoryObject
	"getweaponcritdamage": 1, # ptInventoryObject
	"getweaponfiredelaymax": 1, # ptInventoryObject
	"getweaponfiredelaymin": 1, # ptInventoryObject
	"getweaponfirerate": 1, # ptInventoryObject
	"getweaponflags1": 1, # ptInventoryObject
	"getweaponflags2": 1, # ptInventoryObject
	"getweaponhandgrip": 1, # ptInventoryObject
	"getweaponhasscope": 1, # ptInventoryObject
	"getweaponhealthperc": 0, # no parameters
	"getweaponisautomatic": 1, # ptInventoryObject
	"getweaponlimbdamagemult": 1, # ptInventoryObject
	"getweaponlongbursts": 1, # ptInventoryObject
	"getweaponmaxrange": 1, # ptInventoryObject
	"getweaponminrange": 1, # ptInventoryObject
	"getweaponminspread": 1, # ptInventoryObject
	"getweaponnumprojectiles": 1, # ptInventoryObject
	"getweaponreach": 1, # ptInventoryObject
	"getweaponregenrate": 1, # ptInventoryObject
	"getweaponreloadanim": 1, # ptInventoryObject
	"getweaponrequiredskill": 1, # ptInventoryObject
	"getweaponrequiredstrength": 1, # ptInventoryObject
	"getweaponresisttype": 1, # ptInventoryObject
	"getweaponrumbleduration": 1, # ptInventoryObject
	"getweaponrumbleleftmotor": 1, # ptInventoryObject
	"getweaponrumblerightmotor": 1, # ptInventoryObject
	"getweaponrumblewavelength": 1, # ptInventoryObject
	"getweaponsightfov": 1, # ptInventoryObject
	"getweaponsightusage": 1, # ptInventoryObject
	"getweaponskill": 1, # ptInventoryObject
	"getweaponspread": 1, # ptInventoryObject
	"getweapontype": 1, # ptInventoryObject
	"getweight": 1, # ptInventoryObject
	"getwindspeed": 0, # no parameters
	"getxpfornextlevel": 0, # no parameters
	"hasammoequipped": 1, # ptInventoryObject
	"hasbeeneaten": 0, # no parameters
	"hasflames": 0, # no parameters
	"hasfrienddisposition": 0, # no parameters
	"hasloaded3d": 0, # no parameters
	"hasmagiceffect": 1, # ptBaseEffect
	"hasownership": 1, # ptReference
	"hasperk": 2, # ptPerk, ptInteger
	"isactor": 0, # no parameters
	"isactoravictim": 0, # no parameters
	"isactorevil": 0, # no parameters
	"isactortalkingthroughactivator": 0, # no parameters
	"isactorusingatorch": 0, # no parameters
	"isalwayshardcore": 0, # no parameters
	"iscellowner": 2, # ptCell, ptOwner
	"ischild": 0, # no parameters
	"iscloudy": 0, # no parameters
	"iscombattarget": 1, # ptActor
	"iscontinuingpackagepcnear": 0, # no parameters
	"iscontrolpressed": 1, # ptInteger
	"iscurrentfurnitureobj": 1, # ptFurniture
	"iscurrentfurnitureref": 1, # ptReference
	"isequippedammoinlist": 1, # ptFormList
	"isessential": 0, # no parameters
	"isfacingup": 0, # no parameters
	"isgoredisabled": 0, # no parameters
	"isgreetingplayer": 0, # no parameters
	"isguard": 0, # no parameters
	"ishardcore": 0, # no parameters
	"ishorsestolen": 0, # no parameters
	"isidleplaying": 0, # no parameters
	"isincombat": 0, # no parameters
	"isincriticalstage": 1, # ptCriticalStage
	"isindangerouswater": 0, # no parameters
	"isininterior": 0, # no parameters
	"isinlist": 1, # ptFormList
	"isinmyownedcell": 0, # no parameters
	"iskeypressed": 2, # ptInteger, ptInteger
	"iskiller": 1, # ptActor
	"iskillerobject": 1, # ptFormList
	"islastidleplayed": 1, # ptIdleForm
	"isleftup": 0, # no parameters
	"islimbgone": 1, # ptBodyLocation
	"ismoving": 0, # no parameters
	"isowned": 1, # ptActor
	"isowner": 1, # ptOwner
	"ispc1stperson": 0, # no parameters
	"ispcamurderer": 0, # no parameters
	"ispcsleeping": 0, # no parameters
	"isplayeractionactive": 1, # ptPlayerAction
	"isplayergrabbedref": 1, # ptReference
	"isplayermovingintonewspace": 0, # no parameters
	"isplayerslastriddenhorse": 0, # no parameters
	"isplayerswimming": 0, # no parameters
	"isplayertagskill": 1, # ptActorValue
	"ispleasant": 0, # no parameters
	"ispowerarmor": 1, # ptInventoryObject
	"isps3": 0, # no parameters
	"isquestitem": 1, # ptInventoryObject
	"israining": 0, # no parameters
	"isrefinlist": 2, # ptFormList, ptFormType
	"isridinghorse": 0, # no parameters
	"isrunning": 0, # no parameters
	"isshieldout": 0, # no parameters
	"issneaking": 0, # no parameters
	"issnowing": 0, # no parameters
	"isspelltarget": 1, # ptEffectItem
	"isswimming": 0, # no parameters
	"istalking": 0, # no parameters
	"istalkingactivatoractor": 1, # ptActor
	"istimepassing": 0, # no parameters
	"istorchout": 0, # no parameters
	"istrespassing": 0, # no parameters
	"isturning": 0, # no parameters
	"iswaiting": 0, # no parameters
	"iswaterobject": 0, # no parameters
	"isweaponinlist": 1, # ptFormList
	"isweaponout": 0, # no parameters
	"isweaponskilltype": 1, # ptActorValue
	"iswin32": 0, # no parameters
	"isxbox": 0, # no parameters
	"listgetformindex": 2, # ptFormList, ptFormType
	"menumode": 1, # ptMenuMode
	"playerinregion": 1, # ptRegion
	"samefaction": 1, # ptActor
	"samefactionaspc": 0, # no parameters
	"samerace": 1, # ptActor
	"sameraceaspc": 0, # no parameters
	"samesex": 1, # ptActor
	"samesexaspc": 0, # no parameters
	"whichservicemenu": 0, # no parameters
}

## By CTDA function index: [name, [xEdit parameter types]].
const BY_INDEX := {
	1: ["GetDistance", ["ptReference"]],
	5: ["GetLocked", []],
	6: ["GetPos", ["ptAxis"]],
	8: ["GetAngle", ["ptAxis"]],
	10: ["GetStartingPos", ["ptAxis"]],
	11: ["GetStartingAngle", ["ptAxis"]],
	12: ["GetSecondsPassed", []],
	14: ["GetActorValue", ["ptActorValue"]],
	18: ["GetCurrentTime", []],
	24: ["GetScale", []],
	25: ["IsMoving", []],
	26: ["IsTurning", []],
	27: ["GetLineOfSight", ["ptReference"]],
	32: ["GetInSameCell", ["ptReference"]],
	35: ["GetDisabled", []],
	36: ["MenuMode", ["ptMenuMode"]],
	39: ["GetDisease", []],
	40: ["GetVampire", []],
	41: ["GetClothingValue", []],
	42: ["SameFaction", ["ptActor"]],
	43: ["SameRace", ["ptActor"]],
	44: ["SameSex", ["ptActor"]],
	45: ["GetDetected", ["ptActor"]],
	46: ["GetDead", []],
	47: ["GetItemCount", ["ptInventoryObject"]],
	48: ["GetGold", []],
	49: ["GetSleeping", []],
	50: ["GetTalkedToPC", []],
	53: ["GetScriptVariable", ["ptReference", "ptVariableName"]],
	56: ["GetQuestRunning", ["ptQuest"]],
	58: ["GetStage", ["ptQuest"]],
	59: ["GetStageDone", ["ptQuest", "ptQuestStage"]],
	60: ["GetFactionRankDifference", ["ptFaction", "ptActor"]],
	61: ["GetAlarmed", []],
	62: ["IsRaining", []],
	63: ["GetAttacked", []],
	64: ["GetIsCreature", []],
	65: ["GetLockLevel", []],
	66: ["GetShouldAttack", ["ptActor"]],
	67: ["GetInCell", ["ptCell"]],
	68: ["GetIsClass", ["ptClass"]],
	69: ["GetIsRace", ["ptRace"]],
	70: ["GetIsSex", ["ptSex"]],
	71: ["GetInFaction", ["ptFaction"]],
	72: ["GetIsID", ["ptBaseObject"]],
	73: ["GetFactionRank", ["ptFaction"]],
	74: ["GetGlobalValue", ["ptGlobal"]],
	75: ["IsSnowing", []],
	76: ["GetDisposition", ["ptActor"]],
	77: ["GetRandomPercent", []],
	79: ["GetQuestVariable", ["ptQuest", "ptVariableName"]],
	80: ["GetLevel", []],
	81: ["GetArmorRating", []],
	84: ["GetDeadCount", ["ptActorBase"]],
	91: ["GetIsAlerted", []],
	98: ["GetPlayerControlsDisabled", ["ptInteger", "ptInteger"]],
	99: ["GetHeadingAngle", ["ptReference"]],
	101: ["IsWeaponOut", []],
	102: ["IsTorchOut", []],
	103: ["IsShieldOut", []],
	106: ["IsFacingUp", []],
	107: ["GetKnockedState", []],
	108: ["GetWeaponAnimType", []],
	109: ["IsWeaponSkillType", ["ptActorValue"]],
	110: ["GetCurrentAIPackage", []],
	111: ["IsWaiting", []],
	112: ["IsIdlePlaying", []],
	116: ["GetMinorCrimeCount", []],
	117: ["GetMajorCrimeCount", []],
	118: ["GetActorAggroRadiusViolated", []],
	122: ["GetCrime", ["ptActor", "ptCrimeType"]],
	123: ["IsGreetingPlayer", []],
	125: ["IsGuard", []],
	127: ["HasBeenEaten", []],
	128: ["GetFatiguePercentage", []],
	129: ["GetPCIsClass", ["ptClass"]],
	130: ["GetPCIsRace", ["ptRace"]],
	131: ["GetPCIsSex", ["ptSex"]],
	132: ["GetPCInFaction", ["ptFaction"]],
	133: ["SameFactionAsPC", []],
	134: ["SameRaceAsPC", []],
	135: ["SameSexAsPC", []],
	136: ["GetIsReference", ["ptReference"]],
	141: ["IsTalking", []],
	142: ["GetWalkSpeed", []],
	143: ["GetCurrentAIProcedure", []],
	144: ["GetTrespassWarningLevel", []],
	145: ["IsTrespassing", []],
	146: ["IsInMyOwnedCell", []],
	147: ["GetWindSpeed", []],
	148: ["GetCurrentWeatherPercent", []],
	149: ["GetIsCurrentWeather", ["ptWeather"]],
	150: ["IsContinuingPackagePCNear", []],
	153: ["CanHaveFlames", []],
	154: ["HasFlames", []],
	157: ["GetOpenState", []],
	159: ["GetSitting", []],
	160: ["GetFurnitureMarkerID", []],
	161: ["GetIsCurrentPackage", ["ptPackage"]],
	162: ["IsCurrentFurnitureRef", ["ptReference"]],
	163: ["IsCurrentFurnitureObj", ["ptFurniture"]],
	170: ["GetDayOfWeek", []],
	172: ["GetTalkedToPCParam", ["ptActor"]],
	175: ["IsPCSleeping", []],
	176: ["IsPCAMurderer", []],
	180: ["GetDetectionLevel", ["ptActor"]],
	182: ["GetEquipped", ["ptInventoryObject"]],
	185: ["IsSwimming", []],
	190: ["GetAmountSoldStolen", []],
	192: ["GetIgnoreCrime", []],
	193: ["GetPCExpelled", ["ptFaction"]],
	195: ["GetPCFactionMurder", ["ptFaction"]],
	197: ["GetPCEnemyofFaction", ["ptFaction"]],
	199: ["GetPCFactionAttack", ["ptFaction"]],
	203: ["GetDestroyed", []],
	214: ["HasMagicEffect", ["ptBaseEffect"]],
	215: ["GetDefaultOpen", []],
	219: ["GetAnimAction", []],
	223: ["IsSpellTarget", ["ptEffectItem"]],
	224: ["GetVATSMode", []],
	225: ["GetPersuasionNumber", []],
	226: ["GetSandman", []],
	227: ["GetCannibal", []],
	228: ["GetIsClassDefault", ["ptClass"]],
	229: ["GetClassDefaultMatch", []],
	230: ["GetInCellParam", ["ptCell", "ptReference"]],
	235: ["GetVatsTargetHeight", []],
	237: ["GetIsGhost", []],
	242: ["GetUnconscious", []],
	244: ["GetRestrained", []],
	246: ["GetIsUsedItem", ["ptBaseObject"]],
	247: ["GetIsUsedItemType", ["ptFormType"]],
	254: ["GetIsPlayableRace", []],
	255: ["GetOffersServicesNow", []],
	258: ["GetUsedItemLevel", []],
	259: ["GetUsedItemActivate", []],
	264: ["GetBarterGold", []],
	265: ["IsTimePassing", []],
	266: ["IsPleasant", []],
	267: ["IsCloudy", []],
	274: ["GetArmorRatingUpperBody", []],
	277: ["GetBaseActorValue", ["ptActorValue"]],
	278: ["IsOwner", ["ptOwner"]],
	280: ["IsCellOwner", ["ptCell", "ptOwner"]],
	282: ["IsHorseStolen", []],
	285: ["IsLeftUp", []],
	286: ["IsSneaking", []],
	287: ["IsRunning", []],
	288: ["GetFriendHit", []],
	289: ["IsInCombat", []],
	300: ["IsInInterior", []],
	304: ["IsWaterObject", []],
	306: ["IsActorUsingATorch", []],
	309: ["IsXBox", []],
	310: ["GetInWorldspace", ["ptWorldSpace"]],
	312: ["GetPCMiscStat", ["ptMiscStat"]],
	313: ["IsActorEvil", []],
	314: ["IsActorAVictim", []],
	315: ["GetTotalPersuasionNumber", []],
	318: ["GetIdleDoneOnce", []],
	320: ["GetNoRumors", []],
	323: ["WhichServiceMenu", []],
	327: ["IsRidingHorse", []],
	332: ["IsInDangerousWater", []],
	338: ["GetIgnoreFriendlyHits", []],
	339: ["IsPlayersLastRiddenHorse", []],
	353: ["IsActor", []],
	354: ["IsEssential", []],
	358: ["IsPlayerMovingIntoNewSpace", []],
	361: ["GetTimeDead", []],
	362: ["GetPlayerHasLastRiddenHorse", []],
	365: ["IsChild", []],
	367: ["GetLastPlayerAction", []],
	368: ["IsPlayerActionActive", ["ptPlayerAction"]],
	370: ["IsTalkingActivatorActor", ["ptActor"]],
	372: ["IsInList", ["ptFormList"]],
	382: ["GetHasNote", ["ptNote"]],
	391: ["GetHitLocation", []],
	392: ["IsPC1stPerson", []],
	397: ["GetCauseofDeath", []],
	398: ["IsLimbGone", ["ptBodyLocation"]],
	399: ["IsWeaponInList", ["ptFormList"]],
	403: ["HasFriendDisposition", []],
	408: ["GetVATSValue", ["ptVATSValueFunction", "ptVATSValueParam"]],
	409: ["IsKiller", ["ptActor"]],
	410: ["IsKillerObject", ["ptFormList"]],
	411: ["GetFactionCombatReaction", ["ptFaction", "ptFaction"]],
	415: ["Exists", ["ptReference"]],
	416: ["GetGroupMemberCount", []],
	417: ["GetGroupTargetCount", []],
	420: ["GetObjectiveCompleted", ["ptQuest", "ptQuestObjective"]],
	421: ["GetObjectiveDisplayed", ["ptQuest", "ptQuestObjective"]],
	427: ["GetIsVoiceType", ["ptVoiceType"]],
	428: ["GetPlantedExplosive", []],
	430: ["IsActorTalkingThroughActivator", []],
	431: ["GetHealthPercentage", []],
	433: ["GetIsObjectType", ["ptFormType"]],
	435: ["GetDialogueEmotion", []],
	436: ["GetDialogueEmotionValue", []],
	438: ["GetIsCreatureType", ["ptCreatureType"]],
	446: ["GetInZone", ["ptEncounterZone"]],
	449: ["HasPerk", ["ptPerk", "ptInteger"]],
	450: ["GetFactionRelation", ["ptActor"]],
	451: ["IsLastIdlePlayed", ["ptIdleForm"]],
	454: ["GetPlayerTeammate", []],
	455: ["GetPlayerTeammateCount", []],
	459: ["GetActorCrimePlayerEnemy", []],
	460: ["GetActorFactionPlayerEnemy", []],
	462: ["IsPlayerTagSkill", ["ptActorValue"]],
	464: ["IsPlayerGrabbedRef", ["ptReference"]],
	471: ["GetDestructionStage", []],
	474: ["GetIsAlignment", ["ptAlignment"]],
	478: ["GetThreatRatio", ["ptActor"]],
	480: ["GetIsUsedItemEquipType", ["ptEquipType"]],
	489: ["GetConcussed", []],
	492: ["GetMapMarkerVisible", []],
	495: ["GetPermanentActorValue", ["ptActorValue"]],
	496: ["GetKillingBlowLimb", []],
	500: ["GetWeaponHealthPerc", []],
	503: ["GetRadiationLevel", []],
	510: ["GetLastHitCritical", []],
	515: ["IsCombatTarget", ["ptActor"]],
	518: ["GetVATSRightAreaFree", ["ptReference"]],
	519: ["GetVATSLeftAreaFree", ["ptReference"]],
	520: ["GetVATSBackAreaFree", ["ptReference"]],
	521: ["GetVATSFrontAreaFree", ["ptReference"]],
	522: ["GetIsLockBroken", []],
	523: ["IsPS3", []],
	524: ["IsWin32", []],
	525: ["GetVATSRightTargetVisible", ["ptReference"]],
	526: ["GetVATSLeftTargetVisible", ["ptReference"]],
	527: ["GetVATSBackTargetVisible", ["ptReference"]],
	528: ["GetVATSFrontTargetVisible", ["ptReference"]],
	531: ["IsInCriticalStage", ["ptCriticalStage"]],
	533: ["GetXPForNextLevel", []],
	546: ["GetQuestCompleted", ["ptQuest"]],
	550: ["IsGoreDisabled", []],
	555: ["GetSpellUsageNum", ["ptEffectItem"]],
	557: ["GetActorsInHigh", []],
	558: ["HasLoaded3D", []],
	573: ["GetReputation", ["ptReputation", "ptInteger"]],
	574: ["GetReputationPct", ["ptReputation", "ptInteger"]],
	575: ["GetReputationThreshold", ["ptReputation", "ptInteger"]],
	586: ["IsHardcore", []],
	601: ["GetForceHitReaction", []],
	607: ["ChallengeLocked", ["ptChallenge"]],
	610: ["GetCasinoWinningStage", ["ptCasino"]],
	612: ["PlayerInRegion", ["ptRegion"]],
	614: ["GetChallengeCompleted", ["ptChallenge"]],
	619: ["IsAlwaysHardcore", []],
	1024: ["GetNVSEVersion", []],
	1025: ["GetNVSERevision", []],
	1026: ["GetNVSEBeta", []],
	1028: ["GetWeight", ["ptInventoryObject"]],
	1029: ["GetHealth", ["ptFormType"]],
	1030: ["GetValue", ["ptInventoryObject"]],
	1034: ["GetType", ["ptFormType"]],
	1036: ["GetEquipType", ["ptInventoryObject"]],
	1038: ["GetWeaponClipRounds", ["ptInventoryObject"]],
	1039: ["GetAttackDamage", ["ptInventoryObject"]],
	1040: ["GetWeaponType", ["ptInventoryObject"]],
	1041: ["GetWeaponMinSpread", ["ptInventoryObject"]],
	1042: ["GetWeaponSpread", ["ptInventoryObject"]],
	1044: ["GetWeaponSightFOV", ["ptInventoryObject"]],
	1045: ["GetWeaponMinRange", ["ptInventoryObject"]],
	1046: ["GetWeaponMaxRange", ["ptInventoryObject"]],
	1047: ["GetWeaponAmmoUse", ["ptInventoryObject"]],
	1048: ["GetWeaponActionPoints", ["ptInventoryObject"]],
	1049: ["GetWeaponCritDamage", ["ptInventoryObject"]],
	1050: ["GetWeaponCritChance", ["ptInventoryObject"]],
	1052: ["GetWeaponFireRate", ["ptInventoryObject"]],
	1053: ["GetWeaponAnimAttackMult", ["ptInventoryObject"]],
	1054: ["GetWeaponRumbleLeftMotor", ["ptInventoryObject"]],
	1055: ["GetWeaponRumbleRightMotor", ["ptInventoryObject"]],
	1056: ["GetWeaponRumbleDuration", ["ptInventoryObject"]],
	1057: ["GetWeaponRumbleWavelength", ["ptInventoryObject"]],
	1058: ["GetWeaponAnimShotsPerSec", ["ptInventoryObject"]],
	1059: ["GetWeaponAnimReloadTime", ["ptInventoryObject"]],
	1060: ["GetWeaponAnimJamTime", ["ptInventoryObject"]],
	1061: ["GetWeaponSkill", ["ptInventoryObject"]],
	1062: ["GetWeaponResistType", ["ptInventoryObject"]],
	1063: ["GetWeaponFireDelayMin", ["ptInventoryObject"]],
	1064: ["GetWeaponFireDelayMax", ["ptInventoryObject"]],
	1065: ["GetWeaponAnimMult", ["ptInventoryObject"]],
	1066: ["GetWeaponReach", ["ptInventoryObject"]],
	1067: ["GetWeaponIsAutomatic", ["ptInventoryObject"]],
	1068: ["GetWeaponHandGrip", ["ptInventoryObject"]],
	1069: ["GetWeaponReloadAnim", ["ptInventoryObject"]],
	1070: ["GetWeaponBaseVATSChance", ["ptInventoryObject"]],
	1071: ["GetWeaponAttackAnimation", ["ptInventoryObject"]],
	1072: ["GetWeaponNumProjectiles", ["ptInventoryObject"]],
	1073: ["GetWeaponAimArc", ["ptInventoryObject"]],
	1074: ["GetWeaponLimbDamageMult", ["ptInventoryObject"]],
	1075: ["GetWeaponSightUsage", ["ptInventoryObject"]],
	1076: ["GetWeaponHasScope", ["ptInventoryObject"]],
	1089: ["ListGetFormIndex", ["ptFormList", "ptFormType"]],
	1098: ["GetEquippedCurrentHealth", ["ptInteger"]],
	1102: ["GetNumItems", []],
	1105: ["GetCurrentHealth", []],
	1107: ["IsKeyPressed", ["ptInteger", "ptInteger"]],
	1131: ["IsControlPressed", ["ptInteger"]],
	1144: ["GetArmorAR", ["ptInventoryObject"]],
	1145: ["IsPowerArmor", ["ptInventoryObject"]],
	1148: ["IsQuestItem", ["ptInventoryObject"]],
	1203: ["GetArmorDT", ["ptInventoryObject"]],
	1212: ["GetWeaponRequiredStrength", ["ptInventoryObject"]],
	1213: ["GetWeaponRequiredSkill", ["ptInventoryObject"]],
	1218: ["GetAmmoSpeed", ["ptInventoryObject"]],
	1219: ["GetAmmoConsumedPercent", ["ptInventoryObject"]],
	1254: ["GetWeaponLongBursts", ["ptInventoryObject"]],
	1256: ["GetWeaponFlags1", ["ptInventoryObject"]],
	1257: ["GetWeaponFlags2", ["ptInventoryObject"]],
	1266: ["GetEquippedWeaponModFlags", []],
	1271: ["HasOwnership", ["ptReference"]],
	1272: ["IsOwned", ["ptActor"]],
	1274: ["GetDialogueTarget", ["ptActor"]],
	1275: ["GetDialogueSubject", ["ptActor"]],
	1276: ["GetDialogueSpeaker", ["ptActor"]],
	1278: ["GetAgeClass", ["ptActorBase"]],
	1286: ["GetTokenValue", ["ptFormType"]],
	1288: ["GetTokenRef", ["ptFormType"]],
	1291: ["GetPaired", ["ptInventoryObject", "ptActorBase"]],
	1292: ["GetRespawn", ["ptACtorBase"]],
	1294: ["GetPermanent", ["ptReference"]],
	1297: ["IsRefInList", ["ptFormList", "ptFormType"]],
	1301: ["GetPackageCount", ["ptReference"]],
	1440: ["IsPlayerSwimming", []],
	1441: ["GetTFC", []],
	1475: ["GetPerkRank", ["ptPerk", "ptActor"]],
	1476: ["GetAltPerkRank", ["ptPerk", "ptActor"]],
	1541: ["GetActorFIKstatus", []],
	1587: ["GetWeaponRegenRate", ["ptInventoryObject"]],
	1590: ["CallFunctionCond", ["ptFormList", "ptInteger"]],
	1623: ["HasAmmoEquipped", ["ptInventoryObject"]],
	1624: ["GetEquippedWeaponCanUseAmmo", ["ptInventoryObject"]],
	1625: ["IsEquippedAmmoInList", ["ptFormList"]],
	1626: ["GetEquippedWeaponUsesAmmoList", ["ptFormList"]],
	1631: ["GetWeaponCanUseAmmo", ["ptInventoryObject", "ptInventoryObject"]],
}

## The function name for a CTDA function index, or "" when unknown.
static func name_for_index(function_index: int) -> String:
	var entry: Array = BY_INDEX.get(function_index, [])
	return String(entry[0]) if not entry.is_empty() else ""

## A condition's parameters as the values a script call would pass, by the
## function's xEdit parameter types: references, base resources, CELL/WRLD
## FormIDs and integers. Parameters the function does not take are omitted.
static func resolve_parameters(condition: ConditionSubrecord) -> Array:
	var entry: Array = BY_INDEX.get(condition.function_index, [])
	var types: Array = entry[1] if not entry.is_empty() else []
	var raw := [condition.parameter_1, condition.parameter_2]
	var out := []
	for i in types.size():
		out.append(resolve_parameter(String(types[i]), int(raw[i])))
	return out

## One raw CTDA parameter word as a value, by its xEdit parameter type. A
## FormID naming nothing resolves to null.
static func resolve_parameter(parameter_type: String, raw: int) -> Variant:
	if INTEGER_PARAMETERS.has(parameter_type) or FORM_ID_PARAMETERS.has(parameter_type):
		return raw
	if raw == 0:
		return null
	var esm_server := EsmReference.get_esm_server()
	if esm_server == null or not esm_server.is_ready():
		return null
	if REFERENCE_PARAMETERS.has(parameter_type):
		if raw == PLAYER_REFERENCE_FORM_ID:
			return esm_server.get_player_reference()
		return esm_server.get_reference("authored:%08X" % raw)
	return esm_server.get_base(raw)
