!
! Copyright (C) 2003-2013 Quantum ESPRESSO and Wannier90 groups
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!-----------------------------------------------------------------------
MODULE wannier2odd
  !---------------------------------------------------------------------
  !
  ! ...  This module contains the procedure to build the Wannier
  ! ...  functions from the PW and Wannier90 outputs and then 
  ! ...  adapt them to the CP-Koopmans code.
  !
  USE kinds,               ONLY : DP
  USE fft_types,           ONLY : fft_type_descriptor
  USE stick_base,          ONLY : sticks_map, sticks_map_deallocate
  !
  !
  IMPLICIT NONE
  !
  SAVE
  !
  PRIVATE
  ! 
  PUBLIC :: wan2odd
  !
  TYPE( fft_type_descriptor ) :: dfftcp
  TYPE( sticks_map ) :: smap_cp
  !
  REAL(DP) :: at_cp(3,3)
  REAL(DP) :: bg_cp(3,3)
  REAL(DP) :: omega_cp
  LOGICAL :: gamma_only_cp=.false.  ! CHECK ALSO npwxcp WHEN USING GAMMA TRICK
  !
  ! in the following all the G-vectors related quantities
  ! connected to the dfftcp are defined
  !
  INTEGER :: npwxcp = 0                      ! eq to npwx (in gvecw)
  INTEGER :: ngmcp = 0                       ! eq to ngm (in gvect)
  INTEGER :: ngmcpx = 0                      ! eq to ngmx (in gvect)
  INTEGER :: ngmcp_g = 0                     ! eq to ngm_g (in gvect)
  INTEGER :: nglcp = 0                       ! eq to ngl (in gvect)
  INTEGER :: gstart_cp = 2                   ! eq to gstart (in gvect)
  REAL(DP), ALLOCATABLE, TARGET :: gg_cp(:)                    ! eq to gg (in gvect)
  REAL(DP), ALLOCATABLE, TARGET :: g_cp(:,:)                   ! eq to g (in gvect)
  REAL(DP), POINTER, PROTECTED :: gl_cp(:)                     ! eq to gl (in gvect)
  INTEGER, ALLOCATABLE, TARGET :: mill_cp(:,:)                 ! eq to mill (in gvect)
  INTEGER, ALLOCATABLE, TARGET :: ig_l2g_cp(:)                 ! eq to ig_l2g (in gvect)
  INTEGER, ALLOCATABLE, TARGET, PROTECTED :: igtongl_cp(:)     ! eq to igtongl (in gvect)
  !
  LOGICAL :: check_fft=.false.     ! if .true. dfftcp is built with the same inputs
                                   ! of dffts. Useful for comparison and to check errors
  !
  ! ...  end of module-scope declarations
  !
CONTAINS
  !
  !---------------------------------------------------------------------
  SUBROUTINE wan2odd
    !-------------------------------------------------------------------
    !
    ! ...  This routine:
    !
    ! ...  1) reads the KS states u_nk(G) from PW and the rotation 
    ! ...     matrices U(k) from Wannier90
    !
    ! ...  2) Fourier transforms u_nk to real-space and extends them 
    ! ...     to the supercell defined by the k-points sampling
    !
    ! ...  3) applies the matrices U(k) and realizes the Wannier 
    ! ...     functions in real space. Then Fourier transforms back
    ! ...     to G-space
    !
    ! ...  4) the Wannier functions are finally written in a CP-readable
    ! ...     file
    !
    USE io_global,           ONLY : stdout, ionode
    USE io_files,            ONLY : nwordwfc, iunwfc, restart_dir
    USE io_base,             ONLY : write_rhog
    USE mp_pools,            ONLY : my_pool_id
    USE mp_bands,            ONLY : my_bgrp_id, root_bgrp_id, &
                                    root_bgrp, intra_bgrp_comm
    USE mp,                  ONLY : mp_sum
    USE wavefunctions,       ONLY : evc, psic
    USE fft_base,            ONLY : dffts
    USE fft_interfaces,      ONLY : invfft, fwfft
    USE buffers,             ONLY : open_buffer, close_buffer, &
                                    save_buffer, get_buffer
    USE lsda_mod,            ONLY : nspin
    USE klist,               ONLY : xk, ngk, igk_k, nkstot, nelec
    USE gvect,               ONLY : ngm
    USE wvfct,               ONLY : nbnd, wg, npwx
    USE cell_base,           ONLY : tpiba, omega
    USE control_flags,       ONLY : gamma_only
    USE constants,           ONLY : eps6
    USE scf,                 ONLY : rho
    USE noncollin_module,    ONLY : npol
    USE wannier,             ONLY : iknum, ikstart, mp_grid
    !
    !
    IMPLICIT NONE
    !
    CHARACTER(LEN=256) :: dirname
    INTEGER :: ik, ikevc, ibnd 
    INTEGER :: npw
    INTEGER :: iunwfcx = 24                  ! unit for supercell wfc file
    INTEGER :: nwordwfcx                     ! nword for supercell wfc
    INTEGER :: io_level = 1
    LOGICAL :: exst
    COMPLEX(DP), ALLOCATABLE :: evcx(:,:)
    COMPLEX(DP), ALLOCATABLE :: psicx(:)
    COMPLEX(DP), ALLOCATABLE :: rhor(:)      ! supercell density in real space
    COMPLEX(DP), ALLOCATABLE :: rhog(:,:)    ! supercell density in G-space
    REAL(DP) :: kvec(3)
    REAL(DP) :: nelec_, charge
    !
    !
    CALL start_clock( 'wannier2odd' )
    CALL setup_scell_fft
    !
    nwordwfcx = nbnd*npwxcp*npol
    ALLOCATE( evcx(npwxcp*npol,nbnd) )
    ALLOCATE( psicx(dfftcp%nnr) )
    ALLOCATE( rhor(dfftcp%nnr) )
    ALLOCATE( rhog(ngmcp,nspin) )
    WRITE(stdout,'(2x, "RICCARDO - check on parallelization - dffts%nnr:", i10)') dffts%nnr
    !
    rhor(:) = ( 0.D0, 0.D0 )
    rhog(:,:) = ( 0.D0, 0.D0 )
    !
    !
    ! ... open buffer for IO direct-access to the extended wavefunctions
    !
    CALL open_buffer( iunwfcx, 'wfcx', nwordwfcx, io_level, exst )
    !
    ! ... loop to read the primitive cell wavefunctions and 
    ! ... extend them to the supercell. Also the Wannier gauge 
    ! ... matrices U(k) are read here
    ! 
    DO ik = 1, iknum
      !
      ikevc = ik + ikstart - 1
      CALL davcio( evc, 2*nwordwfc, iunwfc, ikevc, -1 )
      npw = ngk(ik)
      kvec(:) = xk(:,ik)
      !
      DO ibnd = 1, nbnd
        !
        psic(:) = (0.D0, 0.D0)
        psicx(:) = (0.D0, 0.D0)
        psic( dffts%nl(igk_k(1:npw,ik)) ) = evc(1:npw, ibnd)
        IF( gamma_only ) psic( dffts%nlm(igk_k(1:npw,ik)) ) = CONJG(evc(1:npw, ibnd))
        CALL invfft( 'Wave', psic, dffts )
        !
        ! ... here we extend the wfc to the whole supercell
        !
        ! ... NB: the routine extend_wfc applies also the phase factor
        ! ...     e^(ikr) so the output wfc (psicx) is a proper Bloch
        ! ...     function and not just its periodic part
        !
        CALL extend_wfc( psic, psicx, dfftcp, kvec )
        !
        ! ... now we calculate the total density in the supercell
        !
        rhor(:) = rhor(:) + ( DBLE( psicx(:) )**2 + &
                             AIMAG( psicx(:) )**2 ) * wg(ibnd,ik) / omega
        !
        CALL fwfft( 'Wave', psicx, dfftcp )
        IF ( gamma_only_cp ) THEN
          evcx(1:npwxcp,ibnd) = psicx( dfftcp%nlm(1:npwxcp) )  ! THIS DOES NOT WORK!!! TO BE FIXED
        ELSE
          evcx(1:npwxcp,ibnd) = psicx( dfftcp%nl(1:npwxcp) )
        ENDIF
        !
      ENDDO ! ibnd
      !
      ! ... save the extended wavefunctions into the buffer
      !
      CALL save_buffer( evcx, nwordwfcx, iunwfcx, ik )
      !
    ENDDO ! ik
    !
    CALL close_buffer( iunwfcx, 'delete' )
    !
    CALL fwfft( 'Rho', rhor, dfftcp )
    IF ( gamma_only_cp ) THEN
      rhog(1:ngmcp,1) = rhor( dfftcp%nlm(1:ngmcp) )            ! THIS DOES NOT WORK!!! TO BE FIXED
    ELSE
      rhog(1:ngmcp,1) = rhor( dfftcp%nl(1:ngmcp) )
    ENDIF
    !
    ! ... check on the total charge
    !
    charge = 0.D0
    IF ( gstart_cp == 2 ) THEN
      charge = rhog(1,1) * omega_cp
    ENDIF
    CALL mp_sum( charge, intra_bgrp_comm )
    nelec_ = nelec * PRODUCT( mp_grid )
    IF ( check_fft ) nelec_ = nelec
    IF ( ABS( charge - nelec_ ) > 1.D-3 * charge ) &
         CALL errore( 'wan2odd', 'wrong total charge', 1 )
    !
    ! ... check on rho(G) when dfftcp is taken equal to dffts
    !
    IF ( check_fft ) THEN
      DO ik = 1, ngmcp
        IF ( ABS( DBLE(rhog(ik,1) - rho%of_g(ik,1)) ) .ge. eps6 .or. &
             ABS( AIMAG(rhog(ik,1) - rho%of_g(ik,1)) ) .ge. eps6 ) THEN
          CALL errore( 'wan2odd', 'rhog and rho%of_g differ', 1 )
        ENDIF
      ENDDO
    ENDIF
    !
    ! ... write G-space density
    !
    dirname = restart_dir()
    IF ( my_pool_id == 0 .AND. my_bgrp_id == root_bgrp_id ) &
         CALL write_rhog( TRIM(dirname) // "charge-density-x", &
         root_bgrp, intra_bgrp_comm, &
         bg_cp(:,1)*tpiba, bg_cp(:,2)*tpiba, bg_cp(:,3)*tpiba, &
         gamma_only_cp, mill_cp, ig_l2g_cp, rhog(:,:) )
    !
    CALL stop_clock( 'wannier2odd' )
    !
    !
  END SUBROUTINE wan2odd
  !
  !
  !---------------------------------------------------------------------
  SUBROUTINE setup_scell_fft
    !-------------------------------------------------------------------
    !
    ! ...  Here we set up the fft descriptor (dfftcp) for the supercell
    ! ...  commensurate to the Brillouin zone sampling.
    !
    USE wannier,             ONLY : mp_grid
    USE fft_base,            ONLY : smap
    USE mp_bands,            ONLY : nproc_bgrp, intra_bgrp_comm, nyfft, &
                                    ntask_groups, nyfft
    USE mp_pools,            ONLY : inter_pool_comm
    USE mp,                  ONLY : mp_max
    USE io_global,           ONLY : stdout, ionode
    USE fft_base,            ONLY : dffts
    USE fft_types,           ONLY : fft_type_init
    USE gvect,               ONLY : gcutm
    USE gvecs,               ONLY : gcutms
    USE gvecw,               ONLY : gcutw, gkcut
    USE recvec_subs,         ONLY : ggen, ggens
    USE klist,               ONLY : nks, xk
    USE control_flags,       ONLY : gamma_only
    USE cell_base,           ONLY : at, bg, omega
    USE cellmd,              ONLY : lmovecell
    USE realus,              ONLY : real_space
    USE symm_base,           ONLY : fft_fact
    !
    !
    IMPLICIT NONE
    !
    INTEGER, EXTERNAL :: n_plane_waves
    INTEGER :: i, ik
    INTEGER :: ngmcp_
    INTEGER :: nkscp
    REAL(DP), ALLOCATABLE :: xkcp(:,:)
    LOGICAL :: lpara
    !
    !
    CALL get_mp_grid
    !
    DO i = 1, 3
      at_cp(:,i) = at(:,i) * mp_grid(i)
      bg_cp(:,i) = bg(:,i) / mp_grid(i)
    ENDDO
    omega_cp = omega * PRODUCT(mp_grid)
    !
    lpara =  ( nproc_bgrp > 1 )
    gkcut = gcutw
    !
    !
    ! ... uncomment the following line in order to realize dfftcp in the
    ! ... same way of dffts and check possible errors or incosistencies
    !check_fft = .true.
    !
    IF ( check_fft ) THEN
      ! 
      gamma_only_cp = gamma_only
      at_cp(:,:) = at(:,:)
      bg_cp(:,:) = bg(:,:)
      omega_cp = omega
      !
      nkscp = nks
      ALLOCATE( xkcp(3,nkscp) )
      xkcp(:,:) = xk(:,:)
      !
      ! ... calculate gkcut = max |k+G|^2, in (2pi/a)^2 units
      !
      IF (nks == 0) THEN
        !
        ! k-point list not available:
        ! use max(bg)/2 as an estimate of the largest k-point
        !
        gkcut = 0.5d0 * max ( &
            sqrt (sum(bg_cp (1:3, 1)**2) ), &
            sqrt (sum(bg_cp (1:3, 2)**2) ), &
            sqrt (sum(bg_cp (1:3, 3)**2) ) )
      ELSE
        gkcut = 0.0d0
        DO ik = 1, nks
          gkcut = max (gkcut, sqrt ( sum(xk (1:3, ik)**2) ) )
        ENDDO
      ENDIF
      gkcut = (sqrt (gcutw) + gkcut)**2
      !
      ! ... find maximum value among all the processors
      !
      CALL mp_max (gkcut, inter_pool_comm )
      !
    ELSE
      !
      nkscp = 1
      ALLOCATE( xkcp(3,nkscp) )
      xkcp(:,1) = (/ 0.D0, 0.D0, 0.D0 /)
      !
    ENDIF
    !
    ! ... set up the supercell fft descriptor, including parallel 
    ! ... stuff: sticks, planes, etc.
    !
    ! task group are disabled if real_space calculation of calbec is used
    dfftcp%has_task_groups = (ntask_groups >1) .and. .not. real_space
    CALL fft_type_init( dfftcp, smap_cp, "wave", gamma_only_cp, lpara, intra_bgrp_comm,&
                    at_cp, bg_cp, gkcut, gcutms/gkcut, fft_fact, nyfft )
    dfftcp%rho_clock_label='ffts' ; dfftcp%wave_clock_label='fftw'
    !
    ngmcp_ = dfftcp%ngl( dfftcp%mype + 1 )
    IF ( gamma_only_cp ) ngmcp_ = ( ngmcp_ + 1 ) / 2
    CALL gveccp_init( ngmcp_, intra_bgrp_comm )
    !
    !
    ! Some checks (done normally in allocate_fft)
    !
    IF (dfftcp%nnr < ngmcp) THEN
      WRITE( stdout, '(/,4x," nr1cp=",i4," nr2cp= ", i4, " nr3cp=",i4, &
          &" nnrcp= ",i8," ngmcp=",i8)') dfftcp%nr1, dfftcp%nr2, dfftcp%nr3, dfftcp%nnr, ngmcp
      CALL errore( 'setup_scell_fft', 'the nrs"s are too small!', 1 )
    ENDIF 
    !
    IF (ngmcp  <= 0)      CALL errore( 'setup_scell_fft', 'wrong ngmcp' , 1 )
    IF (dfftcp%nnr <= 0) CALL errore( 'setup_scell_fft', 'wrong nnr',  1 )
    !
    ! NB: ggen normally would have dfftp and ggens dffts... here I put dfftcp in both !!!
    CALL ggen ( dfftcp, gamma_only_cp, at_cp, bg_cp, gcutm, ngmcp_g, ngmcp, &
         g_cp, gg_cp, mill_cp, ig_l2g_cp, gstart_cp )
    CALL ggens( dfftcp, gamma_only_cp, at_cp, g_cp, gg_cp, mill_cp, gcutms, ngmcp )
    CALL gshells_cp( lmovecell )
    CALL fftcp_base_info( ionode, stdout )
    !
    !
    ! find the number of PWs for the supercell wfc
    npwxcp = n_plane_waves( gcutw, nkscp, xkcp, g_cp, ngmcp )
    !
    IF ( check_fft ) CALL compare_dfft( dffts, dfftcp )
    !
    !
  END SUBROUTINE setup_scell_fft
  !
  !
  !---------------------------------------------------------------------
  SUBROUTINE extend_wfc( psic, psicx, dfftx, kvec )
    !-------------------------------------------------------------------
    !
    ! ...  Here we extend in real space the periodic part of the Bloch
    ! ...  functions from the PW unit cell to the whole extension of 
    ! ...  BVK boundary conditions (supercell).
    !
    ! ...  psic  : input wfc defined on the unit cell
    ! ...  psicx : output wfc extended to the supercell
    ! ...  dfftx : fft descriptor of the supercell
    !
    USE io_global,           ONLY : stdout
    USE mp,                  ONLY : mp_sum
    USE mp_bands,            ONLY : intra_bgrp_comm
    USE fft_support,         ONLY : good_fft_dimension
    USE fft_base,            ONLY : dffts
    USE constants,           ONLY : eps8, tpi
    !
    !
    IMPLICIT NONE
    !
    COMPLEX(DP), INTENT(IN) :: psic(:)       ! input pcell wfc
    COMPLEX(DP), INTENT(OUT) :: psicx(:)     ! output supercell wfc
    TYPE( fft_type_descriptor ) :: dfftx     ! fft descriptor for the supercell
    REAL(DP), INTENT(IN) :: kvec(3)          ! k-vector for the phase factor 
    !
    COMPLEX(DP), ALLOCATABLE :: psicg(:)     ! global pcell wfc
    COMPLEX(DP) :: phase                     ! phase factor e^(ikr)
    INTEGER :: nnrg
    INTEGER :: i, j, k, ir, ir_end, idx, j0, k0
    INTEGER :: ip, jp, kp
    REAL(DP) :: r(3)
    REAL(DP) :: dot_prod
    !
    !
    ! ... broadcast the unit cell wfc to all the procs 
    !
    nnrg = dffts%nnr
    CALL mp_sum( nnrg, intra_bgrp_comm )
    ALLOCATE( psicg(nnrg) )
    CALL bcast_psic( psic, psicg )
    !
    !
#if defined (__MPI)
    j0 = dfftx%my_i0r2p
    k0 = dfftx%my_i0r3p
    IF( dfftx%nr1x == 0 ) dfftx%nr1x = good_fft_dimension( dfftx%nr1 )
    ir_end = MIN( dfftx%nnr, dfftx%nr1x*dfftx%my_nr2p*dfftx%my_nr3p )
#else
    j0 = 0
    k0 = 0
    ir_end = dfftx%nnr
#endif
    !
    !
    DO ir = 1, ir_end
      !
      ! ... three dimensional indexes
      !
      idx = ir - 1
      k = idx / ( dfftx%nr1x * dfftx%my_nr2p )
      idx = idx - ( dfftx%nr1x * dfftx%my_nr2p ) * k
      k = k + k0
      IF ( k .GE. dfftx%nr3 ) CYCLE
      j = idx / dfftx%nr1x
      idx = idx - dfftx%nr1x * j
      j = j + j0
      IF ( j .GE. dfftx%nr2 ) CYCLE
      i = idx
      IF ( i .GE. dfftx%nr1 ) CYCLE
      !
      ! ... ip, jp and kp represent the indexes folded into the 
      ! ... reference unit cell
      !
      ip = MOD( i, dffts%nr1 )
      jp = MOD( j, dffts%nr2 )
      kp = MOD( k, dffts%nr3 )
      !
      psicx(ir) = psicg( ip + jp*dffts%nr1x + kp*dffts%nr1x*dffts%my_nr2p + 1 )
      !
      ! ... check on psicx when dfftcp is taken equal to dffts
      !
      IF ( check_fft ) THEN
        IF ( ABS( DBLE(psicx(ir) - psic(ir)) ) .ge. eps8 .or. &
             ABS( AIMAG(psicx(ir) - psic(ir)) ) .ge. eps8 ) THEN
          CALL errore( 'extend_wfc', 'psicx and psic differ', 1 )
        ENDIF
      ENDIF
      !
      ! ... calculate the phase factor e^(ikr) and applies it to psicx
      !
      r(1) = DBLE(i) / dfftx%nr1
      r(2) = DBLE(j) / dfftx%nr2
      r(3) = DBLE(k) / dfftx%nr3
      !
      dot_prod = tpi * SUM( kvec(:) * r(:) )
      phase = CMPLX( COS(dot_prod), SIN(dot_prod), KIND=DP )
      psicx(ir) = phase * psicx(ir)
      !
    ENDDO
    !
    !
  END SUBROUTINE extend_wfc
  !
  !
  !---------------------------------------------------------------------
  SUBROUTINE bcast_psic( psic, psicg )
    !-------------------------------------------------------------------
    !
    ! ...  This routine broadcasts the local wavefunction (psic)
    ! ...  to all the procs into a global variable psicg indexed
    ! ...  following the global ordering of the points in the
    ! ...  FFT grid
    !
    USE fft_support,         ONLY : good_fft_dimension
    USE fft_base,            ONLY : dffts
    !
    !
    IMPLICIT NONE
    !
    COMPLEX(DP), INTENT(IN) :: psic(:)
    COMPLEX(DP), INTENT(OUT) :: psicg(:)
    !
    INTEGER :: i, j, k, ir, ir_end, idx, j0, k0, irg
    !
    !
#if defined (__MPI)
    j0 = dffts%my_i0r2p
    k0 = dffts%my_i0r3p
    IF( dffts%nr1x == 0 ) dffts%nr1x = good_fft_dimension( dffts%nr1 )
    ir_end = MIN( dffts%nnr, dffts%nr1x*dffts%my_nr2p*dffts%my_nr3p )
#else
    j0 = 0
    k0 = 0
    ir_end = dffts%nnr
#endif
    !
    !
    DO ir = 1, ir_end
      !
      ! ... three dimensional indexes
      !
      idx = ir - 1
      k = idx / ( dffts%nr1x * dffts%my_nr2p )
      idx = idx - ( dffts%nr1x * dffts%my_nr2p ) * k
      k = k + k0
      IF ( k .GE. dffts%nr3 ) CYCLE
      j = idx / dffts%nr1x
      idx = idx - dffts%nr1x * j
      j = j + j0
      IF ( j .GE. dffts%nr2 ) CYCLE
      i = idx
      IF ( i .GE. dffts%nr1 ) CYCLE
      !
      ! ... defining global index and saving psicg
      !
      irg = i + j*dffts%nr1x + k*dffts%nr1x*dffts%my_nr2p + 1
      psicg(irg) = psic(ir)
      !
    ENDDO    
    !
    !
  END SUBROUTINE bcast_psic
  !
  !
  !---------------------------------------------------------------------
  SUBROUTINE get_mp_grid
    !-------------------------------------------------------------------
    !
    USE klist,               ONLY : xk
    USE cell_base,           ONLY : at
    USE wannier,             ONLY : kpt_latt, iknum
    !
    !
    IMPLICIT NONE
    !
    !
    ALLOCATE( kpt_latt(3,iknum) )
    kpt_latt = xk(:,1:iknum) 
    CALL cryst_to_cart( iknum, kpt_latt, at, -1 )
    !
    CALL find_mp_grid
    !
    !
  END SUBROUTINE get_mp_grid
  !
  !
  !---------------------------------------------------------------------
  SUBROUTINE fftcp_base_info( ionode, stdout )
    !-------------------------------------------------------------------
    !
    LOGICAL, INTENT(IN) :: ionode
    INTEGER, INTENT(IN) :: stdout
    !
    !  Display fftcp basic information
    !
    IF (ionode) THEN
       WRITE( stdout,*)
       IF ( check_fft ) THEN
         WRITE( stdout, '(5X,"Info about the pcell FFT")')
         WRITE( stdout, '(5X,"------------------------")')
       ELSE
         WRITE( stdout, '(5X,"Info about the supercell FFT")')
         WRITE( stdout, '(5X,"----------------------------")')
       ENDIF
       WRITE( stdout, '(5X,"sticks:   smooth     PW", &
                      & 5X,"G-vecs:    smooth      PW")')
       IF ( dfftcp%nproc > 1 ) THEN
          WRITE( stdout,'(5X,"Min",5X,I8,I7,13X,I9,I8)') &
             minval(dfftcp%nsp), minval(dfftcp%nsw), &
             minval(dfftcp%ngl), minval(dfftcp%nwl)
          WRITE( stdout,'(5X,"Max",5X,I8,I7,13X,I9,I8)') &
             maxval(dfftcp%nsp), maxval(dfftcp%nsw), &
             maxval(dfftcp%ngl), maxval(dfftcp%nwl)
       END IF
       WRITE( stdout,'(5X,"Sum",5X,I8,I7,13X,I9,I8)') &
          sum(dfftcp%nsp), sum(dfftcp%nsw), &
          sum(dfftcp%ngl), sum(dfftcp%nwl)
       WRITE( stdout, '(/5x,"grid: ",i10," G-vectors", 5x, &
       &               "FFT dimensions: (",i4,",",i4,",",i4,")")') &
       &         ngmcp_g, dfftcp%nr1, dfftcp%nr2, dfftcp%nr3
       IF ( .not. check_fft ) THEN
         IF ( gamma_only_cp ) THEN
           WRITE( stdout, '(/5X,"Gamma-only algorithm is used &
                          --> real wavefunctions")')
         ELSE
           WRITE( stdout, '(/5X,"Gamma-only algorithm is not used &
                          --> complex wavefunctions")')
         ENDIF
       ENDIF
    ENDIF
    !
    IF(ionode) WRITE( stdout,*)
    !
    RETURN
    !
    !
  END SUBROUTINE fftcp_base_info
  !
  !
  !---------------------------------------------------------------------
  SUBROUTINE gveccp_init( ngmcp_ , comm )
    !-------------------------------------------------------------------
    !
    ! Set local and global dimensions, allocate arrays
    !
    USE mp,                  ONLY : mp_max, mp_sum
    !
    !
    IMPLICIT NONE
    !
    INTEGER, INTENT(IN) :: ngmcp_
    INTEGER, INTENT(IN) :: comm  ! communicator of the group on which g-vecs are distributed
    !
    !
    ngmcp = ngmcp_
    !
    !  calculate maximum over all processors
    !
    ngmcpx = ngmcp
    CALL mp_max( ngmcpx, comm )
    !
    !  calculate sum over all processors
    !
    ngmcp_g = ngmcp
    CALL mp_sum( ngmcp_g, comm )
    !
    !  allocate arrays - only those that are always kept until the end
    !
    ALLOCATE( gg_cp(ngmcp) )
    ALLOCATE( g_cp(3, ngmcp) )
    ALLOCATE( mill_cp(3, ngmcp) )
    ALLOCATE( ig_l2g_cp(ngmcp) )
    ALLOCATE( igtongl_cp(ngmcp) )
    !
    RETURN
    !
    !
  END SUBROUTINE gveccp_init
  !
  !
  !-----------------------------------------------------------------------
  SUBROUTINE gshells_cp ( vc )
    !----------------------------------------------------------------------
    !
    ! calculate number of G shells for the supercell: nglcp, and the 
    ! index ng = igtongl_cp(ig) that gives the shell index ng for 
    ! (local) G-vector of index ig
    !
    USE kinds,              ONLY : DP
    USE constants,          ONLY : eps8
    !
    !
    IMPLICIT NONE
    !
    LOGICAL, INTENT(IN) :: vc
    !
    INTEGER :: ng, igl
    !
    !
    IF ( vc ) THEN
      !
      ! in case of a variable cell run each G vector has its shell
      !
      nglcp = ngmcp
      gl_cp => gg_cp
      !
      DO ng = 1, ngmcp
        igtongl_cp (ng) = ng
      ENDDO
      !
    ELSE
      !
      ! G vectors are grouped in shells with the same norm
      !
      nglcp = 1
      igtongl_cp (1) = 1
      !
      DO ng = 2, ngmcp
        IF (gg_cp (ng) > gg_cp (ng - 1) + eps8) THEN
          nglcp = nglcp + 1
        ENDIF
        igtongl_cp (ng) = nglcp
      ENDDO
      !
      ALLOCATE ( gl_cp(nglcp) )
      gl_cp (1) = gg_cp (1)
      igl = 1
      !
      DO ng = 2, ngmcp
        IF (gg_cp (ng) > gg_cp (ng - 1) + eps8) THEN
          igl = igl + 1
          gl_cp (igl) = gg_cp (ng)
        ENDIF
      ENDDO
      !
    IF (igl /= nglcp) CALL errore ('gshells_cp', 'igl <> ngl', nglcp)
    !
    ENDIF
    !
    !
  END SUBROUTINE gshells_cp 
  !
  !
  !---------------------------------------------------------------------
  SUBROUTINE compare_dfft( dfft1, dfft2 )
    !-------------------------------------------------------------------
    !
    USE io_global,           ONLY : stdout
    !
    !
    IMPLICIT NONE
    !
    TYPE( fft_type_descriptor ), INTENT(INOUT) :: dfft1, dfft2
    !
    !
    IF ( dfft1%nr1 .ne. dfft2%nr1 ) THEN
      WRITE(stdout,*) "Mismatch in nr1", dfft1%nr1, dfft2%nr1
    ENDIF
    !
    IF ( dfft1%nr2 .ne. dfft2%nr2 ) THEN
      WRITE(stdout,*) "Mismatch in nr2", dfft1%nr2, dfft2%nr2
    ENDIF
    !
    IF ( dfft1%nr3 .ne. dfft2%nr3 ) THEN
      WRITE(stdout,*) "Mismatch in nr3", dfft1%nr3, dfft2%nr3
    ENDIF
    !
    IF ( dfft1%nr1x .ne. dfft2%nr1x ) THEN
      WRITE(stdout,*) "Mismatch in nr1x", dfft1%nr1x, dfft2%nr1x
    ENDIF
    !
    IF ( dfft1%nr2x .ne. dfft2%nr2x ) THEN
      WRITE(stdout,*) "Mismatch in nr2x", dfft1%nr2x, dfft2%nr2x
    ENDIF
    !
    IF ( dfft1%nr3x .ne. dfft2%nr3x ) THEN
      WRITE(stdout,*) "Mismatch in nr3x", dfft1%nr3x, dfft2%nr3x
    ENDIF
    !
    IF ( dfft1%lpara .ne. dfft2%lpara ) THEN
      WRITE(stdout,*) "Mismatch in lpara", dfft1%lpara, dfft2%lpara 
    ENDIF
    !
    IF ( dfft1%lgamma .ne. dfft2%lgamma ) THEN
      WRITE(stdout,*) "Mismatch in lgamma", dfft1%lgamma, dfft2%lgamma
    ENDIF
    !
    IF ( dfft1%root .ne. dfft2%root ) THEN
      WRITE(stdout,*) "Mismatch in root", dfft1%root, dfft2%root
    ENDIF
    !
    IF ( dfft1%comm .ne. dfft2%comm ) THEN
      WRITE(stdout,*) "Mismatch in comm", dfft1%comm, dfft2%comm
    ENDIF
    !
    IF ( dfft1%comm2 .ne. dfft2%comm2 ) THEN
      WRITE(stdout,*) "Mismatch in comm2", dfft1%comm2, dfft2%comm2
    ENDIF
    !
    IF ( dfft1%comm3 .ne. dfft2%comm3 ) THEN
      WRITE(stdout,*) "Mismatch in comm3", dfft1%comm3, dfft2%comm3
    ENDIF
    !
    IF ( dfft1%nproc .ne. dfft2%nproc ) THEN
      WRITE(stdout,*) "Mismatch in nproc", dfft1%nproc, dfft2%nproc
    ENDIF
    !
    IF ( dfft1%nproc2 .ne. dfft2%nproc2 ) THEN
      WRITE(stdout,*) "Mismatch in nproc2", dfft1%nproc2, dfft2%nproc2
    ENDIF
    !
    IF ( dfft1%nproc3 .ne. dfft2%nproc3 ) THEN
      WRITE(stdout,*) "Mismatch in nproc3", dfft1%nproc3, dfft2%nproc3
    ENDIF
    !
    IF ( dfft1%mype .ne. dfft2%mype ) THEN
      WRITE(stdout,*) "Mismatch in mype", dfft1%mype, dfft2%mype
    ENDIF
    !
    IF ( dfft1%mype2 .ne. dfft2%mype2 ) THEN
      WRITE(stdout,*) "Mismatch in mype2", dfft1%mype2, dfft2%mype2
    ENDIF
    !
    IF ( dfft1%mype3 .ne. dfft2%mype3 ) THEN
      WRITE(stdout,*) "Mismatch in mype3", dfft1%mype3, dfft2%mype3
    ENDIF
    !
    IF ( ALL(dfft1%iproc .ne. dfft2%iproc) ) THEN
      WRITE(stdout,*) "Mismatch in iproc", dfft1%iproc, dfft2%iproc
    ENDIF
    !
    IF ( ALL(dfft1%iproc2 .ne. dfft2%iproc2) ) THEN
      WRITE(stdout,*) "Mismatch in iproc2", dfft1%iproc2, dfft2%iproc2
    ENDIF
    !
    IF ( ALL(dfft1%iproc3 .ne. dfft2%iproc3) ) THEN
      WRITE(stdout,*) "Mismatch in iproc3", dfft1%iproc3, dfft2%iproc3
    ENDIF
    !
    IF ( dfft1%my_nr3p .ne. dfft2%my_nr3p ) THEN
      WRITE(stdout,*) "Mismatch in my_nr3p", dfft1%my_nr3p, dfft2%my_nr3p
    ENDIF
    !
    IF ( dfft1%my_nr2p .ne. dfft2%my_nr2p ) THEN
      WRITE(stdout,*) "Mismatch in my_nr2p", dfft1%my_nr2p, dfft2%my_nr2p
    ENDIF
    !
    IF ( dfft1%my_i0r3p .ne. dfft2%my_i0r3p ) THEN
      WRITE(stdout,*) "Mismatch in my_i0r3p", dfft1%my_i0r3p, dfft2%my_i0r3p
    ENDIF
    !
    IF ( dfft1%my_i0r2p .ne. dfft2%my_i0r2p ) THEN
      WRITE(stdout,*) "Mismatch in my_i0r2p", dfft1%my_i0r2p, dfft2%my_i0r2p
    ENDIF
    !
    IF ( ALL(dfft1%nr3p .ne. dfft2%nr3p) ) THEN
      WRITE(stdout,*) "Mismatch in nr3p", dfft1%nr3p, dfft2%nr3p
    ENDIF
    !
    IF ( ALL(dfft1%nr3p_offset .ne. dfft2%nr3p_offset) ) THEN
      WRITE(stdout,*) "Mismatch in nr3p_offset", dfft1%nr3p_offset, dfft2%nr3p_offset
    ENDIF
    !
    IF ( ALL(dfft1%nr2p .ne. dfft2%nr2p) ) THEN
      WRITE(stdout,*) "Mismatch in nr2p", dfft1%nr2p, dfft2%nr2p
    ENDIF
    !
    IF ( ALL(dfft1%nr2p_offset .ne. dfft2%nr2p_offset) ) THEN
      WRITE(stdout,*) "Mismatch in nr2p_offset", dfft1%nr2p_offset, dfft2%nr2p_offset
    ENDIF
    !
    IF ( ALL(dfft1%nr1p .ne. dfft2%nr1p) ) THEN
      WRITE(stdout,*) "Mismatch in nr1p", dfft1%nr1p, dfft2%nr1p
    ENDIF
    !
    IF ( ALL(dfft1%nr1w .ne. dfft2%nr1w) ) THEN
      WRITE(stdout,*) "Mismatch in nr1w", dfft1%nr1w, dfft2%nr1w
    ENDIF
    !
    IF ( dfft1%nr1w_tg .ne. dfft2%nr1w_tg ) THEN
      WRITE(stdout,*) "Mismatch in nr1w_tg", dfft1%nr1w_tg, dfft2%nr1w_tg
    ENDIF
    !
    IF ( ALL(dfft1%i0r3p .ne. dfft2%i0r3p) ) THEN
      WRITE(stdout,*) "Mismatch in i0r3p", dfft1%i0r3p, dfft2%i0r3p
    ENDIF
    !
    IF ( ALL(dfft1%i0r2p .ne. dfft2%i0r2p) ) THEN
      WRITE(stdout,*) "Mismatch in i0r2p", dfft1%i0r2p, dfft2%i0r2p
    ENDIF
    !
    IF ( ALL(dfft1%ir1p .ne. dfft2%ir1p) ) THEN
      WRITE(stdout,*) "Mismatch in ir1p", dfft1%ir1p, dfft2%ir1p
    ENDIF
    !
    IF ( ALL(dfft1%indp .ne. dfft2%indp) ) THEN
      WRITE(stdout,*) "Mismatch in indp", dfft1%indp, dfft2%indp
    ENDIF
    !
    IF ( ALL(dfft1%ir1w .ne. dfft2%ir1w) ) THEN
      WRITE(stdout,*) "Mismatch in ir1w", dfft1%ir1w, dfft2%ir1w
    ENDIF
    !
    IF ( ALL(dfft1%indw .ne. dfft2%indw) ) THEN
      WRITE(stdout,*) "Mismatch in indw", dfft1%indw, dfft2%indw
    ENDIF
    !
    IF ( ALL(dfft1%ir1w_tg .ne. dfft2%ir1w_tg) ) THEN
      WRITE(stdout,*) "Mismatch in ir1w_tg", dfft1%ir1w_tg, dfft2%ir1w_tg
    ENDIF
    !
    IF ( ALL(dfft1%indw_tg .ne. dfft2%indw_tg) ) THEN
      WRITE(stdout,*) "Mismatch in indw_tg", dfft1%indw_tg, dfft2%indw_tg
    ENDIF
    !
    IF ( dfft1%nst .ne. dfft2%nst ) THEN
      WRITE(stdout,*) "Mismatch in nst", dfft1%nst, dfft2%nst
    ENDIF
    !
    IF ( ALL(dfft1%nsp .ne. dfft2%nsp) ) THEN
      WRITE(stdout,*) "Mismatch in nsp", dfft1%nsp, dfft2%nsp
    ENDIF
    !
    IF ( ALL(dfft1%nsp_offset .ne. dfft2%nsp_offset) ) THEN
      WRITE(stdout,*) "Mismatch in nsp_offset", dfft1%nsp_offset, dfft2%nsp_offset
    ENDIF
    !
    IF ( ALL(dfft1%nsw .ne. dfft2%nsw) ) THEN
      WRITE(stdout,*) "Mismatch in nsw", dfft1%nsw, dfft2%nsw
    ENDIF
    !
    IF ( ALL(dfft1%nsw_offset .ne. dfft2%nsw_offset) ) THEN
      WRITE(stdout,*) "Mismatch in nsw_offset", dfft1%nsw_offset, dfft2%nsw_offset
    ENDIF
    !
    IF ( ALL(dfft1%nsw_tg .ne. dfft2%nsw_tg) ) THEN
      WRITE(stdout,*) "Mismatch in nsw_tg", dfft1%nsw_tg, dfft2%nsw_tg
    ENDIF
    !
    IF ( ALL(dfft1%ngl .ne. dfft2%ngl) ) THEN
      WRITE(stdout,*) "Mismatch in ngl", dfft1%ngl, dfft2%ngl
    ENDIF
    !
    IF ( ALL(dfft1%nwl .ne. dfft2%nwl) ) THEN
      WRITE(stdout,*) "Mismatch in nwl", dfft1%nwl, dfft2%nwl
    ENDIF
    !
    IF ( dfft1%ngm .ne. dfft2%ngm ) THEN
      WRITE(stdout,*) "Mismatch in ngm", dfft1%ngm, dfft2%ngm
    ENDIF
    !
    IF ( dfft1%ngw .ne. dfft2%ngw ) THEN
      WRITE(stdout,*) "Mismatch in ngw", dfft1%ngw, dfft2%ngw
    ENDIF
    !
    IF ( ALL(dfft1%iplp .ne. dfft2%iplp) ) THEN
      WRITE(stdout,*) "Mismatch in iplp", dfft1%iplp, dfft2%iplp
    ENDIF
    !
    IF ( ALL(dfft1%iplw .ne. dfft2%iplw) ) THEN
      WRITE(stdout,*) "Mismatch in iplw", dfft1%iplw, dfft2%iplw
    ENDIF
    !
    IF ( dfft1%nnp .ne. dfft2%nnp ) THEN
      WRITE(stdout,*) "Mismatch in nnp", dfft1%nnp, dfft2%nnp
    ENDIF
    !
    IF ( dfft1%nnr .ne. dfft2%nnr ) THEN
      WRITE(stdout,*) "Mismatch in nnr", dfft1%nnr, dfft2%nnr
    ENDIF
    !
    IF ( dfft1%nnr_tg .ne. dfft2%nnr_tg ) THEN
      WRITE(stdout,*) "Mismatch in nnr_tg", dfft1%nnr_tg, dfft2%nnr_tg
    ENDIF
    !
    IF ( ALL(dfft1%iss .ne. dfft2%iss) ) THEN
      WRITE(stdout,*) "Mismatch in iss", dfft1%iss, dfft2%iss
    ENDIF
    !
    IF ( ALL(dfft1%isind .ne. dfft2%isind) ) THEN
      WRITE(stdout,*) "Mismatch in isind", dfft1%isind, dfft2%isind
    ENDIF
    !
    IF ( ALL(dfft1%ismap .ne. dfft2%ismap) ) THEN
      WRITE(stdout,*) "Mismatch in ismap", dfft1%ismap, dfft2%ismap
    ENDIF
    !
    IF ( ALL(dfft1%nl .ne. dfft2%nl) ) THEN
      WRITE(stdout,*) "Mismatch in nl", dfft1%nl, dfft2%nl
    ENDIF
    !
    IF ( ALL(dfft1%nlm .ne. dfft2%nlm) ) THEN
      WRITE(stdout,*) "Mismatch in nlm", dfft1%nlm, dfft2%nlm
    ENDIF
    !
    IF ( ALL(dfft1%tg_snd .ne. dfft2%tg_snd) ) THEN
      WRITE(stdout,*) "Mismatch in tg_snd", dfft1%tg_snd, dfft2%tg_snd
    ENDIF
    !
    IF ( ALL(dfft1%tg_rcv .ne. dfft2%tg_rcv) ) THEN
      WRITE(stdout,*) "Mismatch in tg_rcv", dfft1%tg_rcv, dfft2%tg_rcv
    ENDIF
    !
    IF ( ALL(dfft1%tg_sdsp .ne. dfft2%tg_sdsp) ) THEN
      WRITE(stdout,*) "Mismatch in tg_sdsp", dfft1%tg_sdsp, dfft2%tg_sdsp
    ENDIF
    !
    IF ( ALL(dfft1%tg_rdsp .ne. dfft2%tg_rdsp) ) THEN
      WRITE(stdout,*) "Mismatch in tg_rdsp", dfft1%tg_rdsp, dfft2%tg_rdsp
    ENDIF
    !
    IF ( dfft1%has_task_groups .ne. dfft2%has_task_groups ) THEN
      WRITE(stdout,*) "Mismatch in has_task_groups", dfft1%has_task_groups, dfft2%has_task_groups
    ENDIF
    !
    IF ( dfft1%rho_clock_label .ne. dfft2%rho_clock_label ) THEN
      WRITE(stdout,*) "Mismatch in rho_clock_label", dfft1%rho_clock_label, dfft2%rho_clock_label
    ENDIF
    !
    IF ( dfft1%wave_clock_label .ne. dfft2%wave_clock_label ) THEN
      WRITE(stdout,*) "Mismatch in wave_clock_label", dfft1%wave_clock_label, dfft2%wave_clock_label
    ENDIF
    !
    IF ( dfft1%grid_id .ne. dfft2%grid_id ) THEN
      WRITE(stdout,*) "Mismatch in grid_id", dfft1%grid_id, dfft2%grid_id
    ENDIF
    !
    !
    !WRITE(stdout,*) 'RICCARDO', dffts%nr1, dfftcp%nr1
    !WRITE(stdout,*) 'RICCARDO', dffts%nr2, dfftcp%nr2
    !WRITE(stdout,*) 'RICCARDO', dffts%nr3, dfftcp%nr3
    !WRITE(stdout,*) 'RICCARDO', dffts%nr1x, dfftcp%nr1x
    !WRITE(stdout,*) 'RICCARDO', dffts%nr2x, dfftcp%nr2x
    !WRITE(stdout,*) 'RICCARDO', dffts%nr3x, dfftcp%nr3x
    !WRITE(stdout,*) 'RICCARDO', dffts%lpara, dfftcp%lpara
    !WRITE(stdout,*) 'RICCARDO', dffts%lgamma, dfftcp%lgamma
    !WRITE(stdout,*) 'RICCARDO', dffts%root, dfftcp%root
    !WRITE(stdout,*) 'RICCARDO', dffts%comm, dfftcp%comm
    !WRITE(stdout,*) 'RICCARDO', dffts%comm2, dfftcp%comm2
    !WRITE(stdout,*) 'RICCARDO', dffts%comm3, dfftcp%comm3
    !WRITE(stdout,*) 'RICCARDO', dffts%nproc, dfftcp%nproc
    !WRITE(stdout,*) 'RICCARDO', dffts%nproc2, dfftcp%nproc2
    !WRITE(stdout,*) 'RICCARDO', dffts%nproc3, dfftcp%nproc3
    !WRITE(stdout,*) 'RICCARDO', dffts%mype, dfftcp%mype
    !WRITE(stdout,*) 'RICCARDO', dffts%mype2, dfftcp%mype2
    !WRITE(stdout,*) 'RICCARDO', dffts%mype3, dfftcp%mype3
    !WRITE(stdout,*) 'RICCARDO', dffts%iproc, dfftcp%iproc
    !WRITE(stdout,*) 'RICCARDO', dffts%iproc2, dfftcp%iproc2
    !WRITE(stdout,*) 'RICCARDO', dffts%iproc3, dfftcp%iproc3
    !WRITE(stdout,*) 'RICCARDO', dffts%my_nr3p, dfftcp%my_nr3p
    !WRITE(stdout,*) 'RICCARDO', dffts%my_nr2p, dfftcp%my_nr2p
    !WRITE(stdout,*) 'RICCARDO', dffts%my_i0r3p, dfftcp%my_i0r3p
    !WRITE(stdout,*) 'RICCARDO', dffts%my_i0r2p, dfftcp%my_i0r2p
    !WRITE(stdout,*) 'RICCARDO', dffts%nr3p, dfftcp%nr3p
    !WRITE(stdout,*) 'RICCARDO', dffts%nr3p_offset, dfftcp%nr3p_offset
    !WRITE(stdout,*) 'RICCARDO', dffts%nr2p, dfftcp%nr2p
    !WRITE(stdout,*) 'RICCARDO', dffts%nr2p_offset, dfftcp%nr2p_offset
    !WRITE(stdout,*) 'RICCARDO', dffts%nr1p, dfftcp%nr1p
    !WRITE(stdout,*) 'RICCARDO', dffts%nr1w, dfftcp%nr1w
    !WRITE(stdout,*) 'RICCARDO', dffts%nr1w_tg, dfftcp%nr1w_tg
    !WRITE(stdout,*) 'RICCARDO', dffts%i0r3p, dfftcp%i0r3p
    !WRITE(stdout,*) 'RICCARDO', dffts%i0r2p, dfftcp%i0r2p
    !WRITE(stdout,*) 'RICCARDO', dffts%ir1p, dfftcp%ir1p
    !WRITE(stdout,*) 'RICCARDO', dffts%indp, dfftcp%indp
    !WRITE(stdout,*) 'RICCARDO', dffts%ir1w, dfftcp%ir1w
    !WRITE(stdout,*) 'RICCARDO', dffts%indw, dfftcp%indw
    !WRITE(stdout,*) 'RICCARDO', dffts%ir1w_tg, dfftcp%ir1w_tg
    !WRITE(stdout,*) 'RICCARDO', dffts%indw_tg, dfftcp%indw_tg
    !WRITE(stdout,*) 'RICCARDO', dffts%nst, dfftcp%nst
    !WRITE(stdout,*) 'RICCARDO', dffts%nsp, dfftcp%nsp
    !WRITE(stdout,*) 'RICCARDO', dffts%nsp_offset, dfftcp%nsp_offset
    !WRITE(stdout,*) 'RICCARDO', dffts%nsw, dfftcp%nsw
    !WRITE(stdout,*) 'RICCARDO', dffts%nsw_offset, dfftcp%nsw_offset
    !WRITE(stdout,*) 'RICCARDO', dffts%nsw_tg, dfftcp%nsw_tg
    !WRITE(stdout,*) 'RICCARDO', dffts%ngl, dfftcp%ngl
    !WRITE(stdout,*) 'RICCARDO', dffts%nwl, dfftcp%nwl
    !WRITE(stdout,*) 'RICCARDO', dffts%ngm, dfftcp%ngm
    !WRITE(stdout,*) 'RICCARDO', dffts%ngw, dfftcp%ngw
    !WRITE(stdout,*) 'RICCARDO', dffts%iplp, dfftcp%iplp
    !WRITE(stdout,*) 'RICCARDO', dffts%iplw, dfftcp%iplw
    !WRITE(stdout,*) 'RICCARDO', dffts%nnp, dfftcp%nnp
    !WRITE(stdout,*) 'RICCARDO', dffts%nnr, dfftcp%nnr
    !WRITE(stdout,*) 'RICCARDO', dffts%nnr_tg, dfftcp%nnr_tg
    !WRITE(stdout,*) 'RICCARDO', dffts%iss, dfftcp%iss
    !WRITE(stdout,*) 'RICCARDO', dffts%isind, dfftcp%isind
    !WRITE(stdout,*) 'RICCARDO', dffts%ismap, dfftcp%ismap
    !WRITE(stdout,*) 'RICCARDO', dffts%nl, dfftcp%nl
    !WRITE(stdout,*) 'RICCARDO', dffts%nlm, dfftcp%nlm
    !WRITE(stdout,*) 'RICCARDO', dffts%tg_snd, dfftcp%tg_snd
    !WRITE(stdout,*) 'RICCARDO', dffts%tg_rcv, dfftcp%tg_rcv
    !WRITE(stdout,*) 'RICCARDO', dffts%tg_sdsp, dfftcp%tg_sdsp
    !WRITE(stdout,*) 'RICCARDO', dffts%tg_rdsp, dfftcp%tg_rdsp
    !WRITE(stdout,*) 'RICCARDO', dffts%has_task_groups, dfftcp%has_task_groups
    !WRITE(stdout,*) 'RICCARDO', dffts%rho_clock_label, dfftcp%rho_clock_label
    !WRITE(stdout,*) 'RICCARDO', dffts%wave_clock_label, dfftcp%wave_clock_label
    !WRITE(stdout,*) 'RICCARDO', dffts%grid_id, dfftcp%grid_id
    !
    !
  END SUBROUTINE compare_dfft
  !
  !
END MODULE wannier2odd
