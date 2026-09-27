@tool
class_name ScriptConditionFunctions
extends RefCounted

## Parameter counts of the FNV condition functions, by lowercased name: the
## Get*/Is* functions a script can call inside an expression. Source: xEdit's
## wbConditionFunctions (enginedocs/xEdit/Core/wbDefinitionsFNV.pas), indices
## below 4096; the rest are NVSE extensions, out of scope. 338 functions. The
## comment on each is its xEdit parameter types.

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
