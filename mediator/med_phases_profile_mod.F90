module med_phases_profile_mod

  !-----------------------------------------------------------------------------
  ! Output med profile to log file
  !-----------------------------------------------------------------------------

  use med_kind_mod          , only : CX=>SHR_KIND_CX, CS=>SHR_KIND_CS, CL=>SHR_KIND_CL, R8=>SHR_KIND_R8
  use med_constants_mod     , only : dbug_flag=>med_constants_dbug_flag
  use med_utils_mod         , only : med_utils_chkerr, med_memcheck
  use med_internalstate_mod , only : mastertask, logunit
  use med_utils_mod         , only : med_utils_chkerr
  use perf_mod              , only : t_startf, t_stopf
  use shr_mem_mod           , only : shr_mem_getusage

  implicit none
  private

  public  :: med_phases_profile, med_phases_profile_finalize

  character(*), parameter :: u_FILE_u  = &
       __FILE__

  real(R8) :: accumulated_time=0_R8, timestep_length
  real(r8) :: previous_time=0_R8
  integer  :: iterations=0

!=================================================================================
contains
!=================================================================================

  subroutine med_phases_profile(gcomp, rc)

    use ESMF  , only : ESMF_VMGetCurrent, ESMF_CLOCK, ESMF_GridComp, ESMF_LogMsg_Info
    use ESMF  , only : ESMF_LogWrite, ESMF_GridCompGet, ESMF_SUCCESS, ESMF_VM
    use ESMF  , only : ESMF_VMGet, ESMF_ClockGetAlarm, ESMF_AlarmRingerOff
    use ESMF  , only : ESMF_Alarm, ESMF_AlarmisRinging, ESMF_VMWtime
    use ESMF  , only : ESMF_TimeSyncToRealTime, ESMF_Time, ESMF_TimeSet
    use ESMF  , only : ESMF_TimeInterval, ESMF_AlarmGet, ESMF_TimeIntervalGet
    use ESMF  , only : ESMF_ClockGetNextTime, ESMF_TimeGet, ESMF_ClockGet
    use ESMF  , only : operator(-)
    use NUOPC , only : NUOPC_CompAttributeGet

    ! write profile output

    ! Input/output variables
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    character(len=CS)       :: cpl_inst_tag
    type(ESMF_CLOCK)        :: clock
    type(ESMF_TIME)         :: wallclocktime, nexttime
    type(ESMF_TIME), save   :: prevtime
    type(ESMF_VM)           :: vm
    type(ESMF_Alarm)        :: alarm, salarm
    type(ESMF_TimeInterval) :: ringInterval, timestep
    integer                 :: yr, mon, day, hr, min, sec
    integer                 :: iam
    logical                 :: ispresent
    logical                 :: alarmison=.false., stopalarmison=.false.
    real(R8)                :: current_time, wallclockelapsed, ypd
    real(r8)                :: msize, mrss, ringdays
    real(r8), save          :: avgdt
    character(len=CL)       :: walltimestr, nexttimestr
    character(len=*), parameter :: subname='(med_phases_profile)'
    !---------------------------------------

    call t_startf('MED:'//subname)
    call ESMF_LogWrite(trim(subname)//": called", ESMF_LOGMSG_INFO, rc=rc)
    rc = ESMF_SUCCESS

    call ESMF_VMGetCurrent(vm, rc=rc)
    if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

    call ESMF_VMGet(vm, localPet=iam, rc=rc)
    if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

    call NUOPC_CompAttributeGet(gcomp, name='inst_suffix', isPresent=isPresent, rc=rc)
    if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

    if(isPresent) then
       call NUOPC_CompAttributeGet(gcomp, name='inst_suffix', value=cpl_inst_tag, rc=rc)
       if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
    else
       cpl_inst_tag = ""
    endif

    !---------------------------------------
    ! --- profiler Alarm
    !---------------------------------------
    call ESMF_GridCompGet(gcomp, clock=clock, rc=rc)
    if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
    if (iterations == 0) then
       ! intialize and return
       call ESMF_VMWtime(previous_time, rc=rc)
       if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
       ! Here we are just getting a single timestep interval
       call ESMF_ClockGet( clock, timestep=timestep, rc=rc)
       if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

       call ESMF_ClockGet(clock, currTime=prevtime, rc=rc)
       if (med_utils_ChkErr(rc,__LINE__,u_FILE_u)) return

       call ESMF_TimeIntervalGet(timestep, d_r8=timestep_length, rc=rc)
       if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
       iterations = 1
    else
       !---------------------------------------
       ! --- Get the clock info
       !---------------------------------------

       call ESMF_ClockGetAlarm(clock, alarmname='med_profile_alarm', alarm=alarm, rc=rc)
       if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

       if (ESMF_AlarmIsRinging(alarm, rc=rc)) then
          if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
          alarmIsOn = .true.
          call ESMF_AlarmRingerOff( alarm, rc=rc )
          if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
       else
          call ESMF_ClockGetAlarm(clock, alarmname='alarm_stop', alarm=salarm, rc=rc)
          if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
          if (ESMF_AlarmIsRinging(salarm, rc=rc)) then
             if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
             stopalarmIsOn = .true.
             call ESMF_AlarmRingerOff( salarm, rc=rc )
             if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
          else
             AlarmIsOn = .false.
             stopalarmison = .false.
          endif
       endif
       if ((stopalarmison .or. alarmIsOn .or. iterations==1) .and. mastertask) then
          ! We need to get the next time for display
          call ESMF_ClockGetNextTime(clock, nextTime=nexttime, rc=rc)
          if (med_utils_ChkErr(rc,__LINE__,u_FILE_u)) return

          call ESMF_VMWtime(current_time, rc=rc)
          if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

          wallclockelapsed = current_time - previous_time
          accumulated_time = accumulated_time + wallclockelapsed

          if (alarmison) then
             call ESMF_AlarmGet( alarm, ringInterval=ringInterval, rc=rc)
             if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
             call ESMF_TimeIntervalGet(ringInterval, d_r8=ringdays, rc=rc)
             if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
             avgdt = accumulated_time/(ringdays*real(iterations-1))
          else if (stopalarmison) then
             ! Here we need the interval since the last call to this function
             call ESMF_TimeIntervalGet(nexttime-prevtime, d_r8=ringdays, rc=rc)
             if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
          else
             avgdt = wallclockelapsed/timestep_length
             ringdays = timestep_length
          endif
          prevtime = nexttime
          call ESMF_TimeGet(nexttime, timestring=nexttimestr, rc=rc)
          if (med_utils_ChkErr(rc,__LINE__,u_FILE_u)) return
          ! get current wall clock time
          call ESMF_TimeSet(wallclocktime, rc=rc)
          if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return
          call ESMF_TimeSyncToRealTime(wallclocktime, rc=rc)
          if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

          call ESMF_TimeGet(wallclocktime,timeString=walltimestr, rc=rc)
          if (med_utils_ChkErr(rc,__LINE__,u_FILE_u)) return


          ! 1 model day/ x seconds = 1/365 yrs/ (wallclockelapsed s/86400spd
          ypd = ringdays*86400.0_R8/(365.0_R8*wallclockelapsed)

          write(logunit,101) 'Model Date: ',trim(nexttimestr), ' wall clock = ',trim(walltimestr),' avg dt = ', &
               avgdt, 's/day, dt = ',wallclockelapsed/ringdays,'s/day, rate = ',ypd,' ypd'
          call shr_mem_getusage(msize,mrss,.true.)

          write(logunit,105) ' memory_write: model date = ',trim(nexttimestr), &
               ' memory = ',msize,' MB (highwater)    ',mrss,' MB (usage)'
          previous_time = current_time
       endif
    endif
    iterations = iterations + 1

101 format( 5A, F8.2, A, F8.2, A, F8.2, A)
105 format( 3A, f10.2, A, f10.2, A)
    !---------------------------------------
    !--- clean up
    !---------------------------------------

    call ESMF_LogWrite(trim(subname)//": done", ESMF_LOGMSG_INFO, rc=rc)
    call t_stopf('MED:'//subname)

  end subroutine med_phases_profile

!=================================================================================

  subroutine med_phases_profile_finalize()
    use ESMF, only : ESMF_VMWtime

    real(r8) :: SYPD
    character(*), parameter :: FormatR = '(": =============== ", A31,F12.3,1x,  " ===============")'
    real(r8) :: current_time, wallclockelapsed
    integer :: rc

    call ESMF_VMWtime(current_time, rc=rc)
    if (med_utils_chkerr(rc,__LINE__,u_FILE_u)) return

    wallclockelapsed = current_time - previous_time
    accumulated_time = accumulated_time + wallclockelapsed

    SYPD = real(iterations-1,R8)*timestep_length*86400.0_R8/(365.0_R8*accumulated_time)
    write(logunit,FormatR) '# simulated years / cmp-day = ', SYPD

  end subroutine med_phases_profile_finalize

end module med_phases_profile_mod
